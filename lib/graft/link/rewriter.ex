defmodule Graft.Link.Rewriter do
  @moduledoc """
  Pure rewrite engine for `mix.exs` dep tuples.

  Locates the dep tuple matching `app` inside the `def deps` / `defp deps`
  function body and replaces its **source portion** (version string and
  source-related keyword opts like `:path`, `:git`, `:branch`, etc.) with
  a new keyword list. Non-source opts (`:only`, `:optional`, `:runtime`,
  `:targets`, …) are preserved.

  ## Guarantees

    * No filesystem access, no shell-outs, no network calls.
    * No code is evaluated. Sourceror parsing only.
    * Rewriting the same input twice with the same replacement yields
      byte-identical output (deterministic).
    * Only the matching dep tuple is touched. Unrelated deps and
      unrelated code (other functions, attributes, comments) are
      preserved.

  ## Result shape

  Returns `{:ok, %Graft.Link.RewriteResult{}}` on every successful
  parse — including the case where the target dep is absent. In that
  case `matched_dep?: false` and `changed?: false`. Errors are returned
  as `{:error, %Graft.Error{}}` for parse failures, invalid
  replacement opts, or unrecognised dep shapes.
  """

  alias Graft.Error
  alias Graft.Link.RewriteResult

  # Source-related keys in a dep's opts list. These are dropped when we
  # rewrite a dep's source; everything else (only, optional, runtime,
  # targets, …) is preserved verbatim.
  @source_keys [:path, :git, :github, :branch, :tag, :ref, :submodules, :sparse]

  # Replacement opts must contain at least one of these to identify the
  # new source.
  @source_identifier_keys [:path, :git, :github]

  @type replacement_opt :: {atom(), term()}

  @doc """
  Rewrite `contents` so the dep `app` uses `replacement_opts` as its
  source. See module doc for semantics.
  """
  @spec rewrite(String.t(), atom(), [replacement_opt()]) ::
          {:ok, RewriteResult.t()} | {:error, Error.t()}
  def rewrite(contents, app, replacement_opts)
      when is_binary(contents) and is_atom(app) and is_list(replacement_opts) do
    with :ok <- validate_replacement(replacement_opts),
         {:ok, ast} <- safe_parse(contents) do
      case rewrite_ast(ast, app, replacement_opts) do
        {:no_match, _ast} ->
          {:ok,
           %RewriteResult{
             original_contents: contents,
             rewritten_contents: contents,
             changed?: false,
             matched_dep?: false
           }}

        {:match, new_ast, original_dep, rewritten_dep} ->
          rewritten_contents = render(new_ast, contents)

          {:ok,
           %RewriteResult{
             original_contents: contents,
             rewritten_contents: rewritten_contents,
             changed?: contents != rewritten_contents,
             matched_dep?: true,
             original_dep_ast: original_dep,
             rewritten_dep_ast: rewritten_dep
           }}

        {:error, %Error{}} = err ->
          err
      end
    end
  end

  ## ─── Validation ─────────────────────────────────────────────────────

  defp validate_replacement([]) do
    {:error, Error.new(:rewriter_invalid_replacement, "Replacement opts must not be empty")}
  end

  defp validate_replacement(opts) do
    unless Keyword.keyword?(opts) do
      {:error,
       Error.new(:rewriter_invalid_replacement, "Replacement opts must be a keyword list")}
    else
      if Enum.any?(opts, fn {k, _} -> k in @source_identifier_keys end) do
        :ok
      else
        {:error,
         Error.new(
           :rewriter_invalid_replacement,
           "Replacement opts must include one of #{inspect(@source_identifier_keys)}",
           %{got: Keyword.keys(opts)}
         )}
      end
    end
  end

  ## ─── Parse ──────────────────────────────────────────────────────────

  defp safe_parse(contents) do
    {:ok, Sourceror.parse_string!(contents)}
  rescue
    e ->
      {:error,
       Error.new(
         :rewriter_malformed_source,
         "Failed to parse mix.exs: #{Exception.message(e)}"
       )}
  end

  ## ─── Locate + rewrite the deps function ─────────────────────────────

  # Walk the entire AST looking for the `deps` function. When found,
  # rewrite its body and substitute back. The walk continues, but the
  # first match's accumulator is preserved (we don't expect more than
  # one `deps` function).
  defp rewrite_ast(ast, app, replacement_opts) do
    {new_ast, acc} =
      Macro.prewalk(ast, :no_match, fn
        {def_kind, m, [{:deps, dm, ctx}, [{do_kw, body}]]} = node, :no_match
        when def_kind in [:def, :defp] and (is_atom(ctx) or ctx == []) ->
          case rewrite_body(body, app, replacement_opts) do
            {:no_match, new_body} ->
              {{def_kind, m, [{:deps, dm, ctx}, [{do_kw, new_body}]]}, :no_match}

            {:match, new_body, orig, rew} ->
              {{def_kind, m, [{:deps, dm, ctx}, [{do_kw, new_body}]]}, {:match, orig, rew}}

            {:error, _} = err ->
              {node, err}
          end

        node, acc ->
          {node, acc}
      end)

    case acc do
      :no_match -> {:no_match, new_ast}
      {:match, orig, rew} -> {:match, new_ast, orig, rew}
      {:error, _} = err -> err
    end
  end

  ## ─── Rewrite within the deps function body ──────────────────────────

  defp rewrite_body({:__block__, m, [list]}, app, opts) when is_list(list) do
    case rewrite_list(list, app, opts) do
      {:no_match, new_list} -> {:no_match, {:__block__, m, [new_list]}}
      {:match, new_list, o, r} -> {:match, {:__block__, m, [new_list]}, o, r}
      {:error, _} = err -> err
    end
  end

  defp rewrite_body(list, app, opts) when is_list(list) do
    rewrite_list(list, app, opts)
  end

  defp rewrite_body(other, _app, _opts) do
    {:no_match, other}
  end

  defp rewrite_list(list, app, opts) do
    Enum.reduce_while(list, {[], :no_match}, fn elem, {acc, status} ->
      case rewrite_list_element(elem, app, opts, status) do
        {:error, _} = err -> {:halt, err}
        {new_elem, new_status} -> {:cont, {[new_elem | acc], new_status}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      {rev_list, :no_match} -> {:no_match, Enum.reverse(rev_list)}
      {rev_list, {:match, o, r}} -> {:match, Enum.reverse(rev_list), o, r}
    end
  end

  defp rewrite_list_element({:__block__, m, [tuple]}, app, opts, status) when is_tuple(tuple) do
    case rewrite_dep_tuple(tuple, app, opts) do
      {:no_match, _} ->
        {{:__block__, m, [tuple]}, status}

      {:match, new_tuple, orig, rew} ->
        new_status = if status == :no_match, do: {:match, orig, rew}, else: status
        {{:__block__, m, [new_tuple]}, new_status}

      {:error, _} = err ->
        err
    end
  end

  defp rewrite_list_element(tuple, app, opts, status) when is_tuple(tuple) do
    case rewrite_dep_tuple(tuple, app, opts) do
      {:no_match, _} ->
        {tuple, status}

      {:match, new_tuple, orig, rew} ->
        new_status = if status == :no_match, do: {:match, orig, rew}, else: status
        {new_tuple, new_status}

      {:error, _} = err ->
        err
    end
  end

  defp rewrite_list_element(other, _app, _opts, status) do
    {other, status}
  end

  ## ─── Per-tuple rewrite ──────────────────────────────────────────────

  defp rewrite_dep_tuple({name_node, value_node} = original, app, replacement_opts) do
    if unwrap(name_node) == app do
      case classify_value(value_node) do
        :version_string ->
          new_value = build_value_ast(replacement_opts, [])
          new_tuple = {name_node, new_value}
          {:match, new_tuple, original, new_tuple}

        :kw_list ->
          kept = collect_non_source(value_node)
          new_value = build_value_ast(replacement_opts, kept)
          new_tuple = {name_node, new_value}
          {:match, new_tuple, original, new_tuple}

        :unknown ->
          {:error,
           Error.new(
             :rewriter_unknown_dep_shape,
             "Cannot rewrite dep #{inspect(app)}: unrecognised value shape",
             %{app: app}
           )}
      end
    else
      {:no_match, original}
    end
  end

  defp rewrite_dep_tuple(
         {:{}, _m, [name_node, version_node, opts_node]} = original,
         app,
         replacement_opts
       ) do
    if unwrap(name_node) == app do
      case classify_value(version_node) do
        :version_string ->
          kept_from_opts = collect_non_source(opts_node)
          new_value = build_value_ast(replacement_opts, kept_from_opts)
          new_tuple = {name_node, new_value}
          {:match, new_tuple, original, new_tuple}

        _ ->
          {:error,
           Error.new(
             :rewriter_unknown_dep_shape,
             "Cannot rewrite dep #{inspect(app)}: 3-tuple middle slot is not a version string",
             %{app: app}
           )}
      end
    else
      {:no_match, original}
    end
  end

  defp rewrite_dep_tuple(other, _app, _opts), do: {:no_match, other}

  ## ─── Value classification ───────────────────────────────────────────

  defp classify_value(node) do
    case unwrap(node) do
      s when is_binary(s) -> :version_string
      kw when is_list(kw) -> if Keyword.keyword?(unwrap_kw_keys(kw)), do: :kw_list, else: :unknown
      _ -> :unknown
    end
  end

  # Sourceror keyword lists have wrapped keys; checking Keyword.keyword?
  # on the raw kw produces false. Build a shadow list with unwrapped keys
  # for the check.
  defp unwrap_kw_keys(kw) do
    Enum.map(kw, fn
      {k, v} -> {unwrap(k), v}
      other -> other
    end)
  end

  ## ─── Non-source opts retention ──────────────────────────────────────

  defp collect_non_source(node) do
    case unwrap(node) do
      kw when is_list(kw) ->
        Enum.reject(kw, fn
          {k, _v} -> unwrap(k) in @source_keys
          _ -> true
        end)

      _ ->
        []
    end
  end

  ## ─── New value AST construction ─────────────────────────────────────

  # The new value is always a keyword list. We splice the replacement
  # opts (with explicit keyword formatting) before any preserved
  # non-source pairs so the new source identifier (path/git/github)
  # appears first — matching how a developer would naturally write it.
  defp build_value_ast(replacement_opts, kept_pairs) do
    new_pairs = Enum.map(replacement_opts, &build_kw_pair/1)
    new_pairs ++ kept_pairs
  end

  defp build_kw_pair({key, value}) when is_atom(key) do
    {{:__block__, [format: :keyword], [key]}, value_ast(value)}
  end

  defp value_ast(s) when is_binary(s),
    do: {:__block__, [delimiter: ~s(")], [s]}

  defp value_ast(b) when is_boolean(b), do: {:__block__, [], [b]}
  defp value_ast(nil), do: {:__block__, [], [nil]}
  defp value_ast(n) when is_integer(n), do: {:__block__, [token: Integer.to_string(n)], [n]}
  defp value_ast(a) when is_atom(a), do: {:__block__, [], [a]}
  defp value_ast(other), do: other

  ## ─── Render ─────────────────────────────────────────────────────────

  # Sourceror.to_string may not append a trailing newline even if the
  # original had one. Match the original's terminal newline state to
  # keep diffs minimal.
  defp render(ast, original) do
    rendered = Sourceror.to_string(ast)

    cond do
      String.ends_with?(original, "\n") and not String.ends_with?(rendered, "\n") ->
        rendered <> "\n"

      not String.ends_with?(original, "\n") and String.ends_with?(rendered, "\n") ->
        String.trim_trailing(rendered, "\n")

      true ->
        rendered
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp unwrap({:__block__, _, [v]}), do: v
  defp unwrap(other), do: other
end
