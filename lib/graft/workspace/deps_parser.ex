defmodule Graft.Workspace.DepsParser do
  @moduledoc """
  Parses dependency tuples out of a sibling repo's `mix.exs`.

  Side-effect free: takes a source string, returns structured deps.
  Never raises — unparseable inputs return `[]`.

  ## Supported shapes (v0.1)

  Common inline tuples in a `def deps` / `defp deps` body:

      {:foo, "~> 1.0"}                              # :hex
      {:foo, "~> 1.0", only: :test}                 # :hex
      {:foo, path: "../foo"}                        # :path
      {:foo, "~> 1.0", path: "../foo"}              # :path  (override wins)
      {:foo, git: "https://...", tag: "v1"}         # :git
      {:foo, github: "owner/foo"}                   # :git

  Anything else with an atom in the first slot is preserved as `:unknown`.
  """

  alias Graft.Workspace.Dependency

  @doc """
  Parse a `mix.exs` source string into a list of `%Dependency{}` for `repo`.

  Robust against malformed sources: returns `[]` on parse failure.
  """
  @spec parse(String.t(), atom()) :: [Dependency.t()]
  def parse(source, repo) when is_binary(source) and is_atom(repo) do
    case safe_parse(source) do
      {:ok, ast} ->
        ast
        |> find_deps_body()
        |> peel_to_list()
        |> Enum.map(&build_dependency(&1, repo))
        |> Enum.reject(&is_nil/1)

      :error ->
        []
    end
  end

  ## ─── Parse step ─────────────────────────────────────────────────────

  defp safe_parse(source) do
    {:ok, Sourceror.parse_string!(source)}
  rescue
    _ -> :error
  end

  ## ─── Locate the deps function body ──────────────────────────────────

  defp find_deps_body(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {def_kind, _, [{:deps, _, ctx}, [{_do_kw, body}]]} = node, nil
        when def_kind in [:def, :defp] and (is_atom(ctx) or ctx == []) ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    found
  end

  ## ─── Peel the deps function body down to its top-level list ────────

  # The body of `defp deps do [...] end` parses as either:
  #   {:__block__, meta, [list_literal]}     -- single-expression body
  #   list_literal                           -- raw list (rare)
  # We strip off any single-element __block__ wrappers until we hit a list,
  # then return its top-level elements. Anything else (e.g. a multi-statement
  # body, or `deps = [...]` then `deps`) returns [] — out of scope for v0.1.

  defp peel_to_list(nil), do: []
  defp peel_to_list({:__block__, _, [inner]}), do: peel_to_list(inner)
  defp peel_to_list(list) when is_list(list), do: list
  defp peel_to_list(_), do: []

  ## ─── Per-dep classification ─────────────────────────────────────────

  # Sourceror wraps each list element in `__block__` to carry trivia
  # (commas, comments). Peel that wrapper before classifying.
  defp build_dependency({:__block__, _, [inner]}, repo) when is_tuple(inner) do
    build_dependency(inner, repo)
  end

  # Tuples with arity != 2 are represented in Elixir AST as
  # `{:{}, meta, [elements]}`. We care about the 3-element case (dep with
  # version + opts).
  defp build_dependency({:{}, _, [name_node, value_node, opts_node]} = ast, repo) do
    %Dependency{
      repo: repo,
      app: unwrap(name_node),
      raw: render(ast),
      source: classify_three(value_node, opts_node)
    }
  end

  defp build_dependency({name_node, value_node} = ast, repo) do
    %Dependency{
      repo: repo,
      app: unwrap(name_node),
      raw: render(ast),
      source: classify_value(value_node)
    }
  end

  defp build_dependency(_other, _repo), do: nil

  defp classify_value(value_node) do
    case unwrap(value_node) do
      s when is_binary(s) -> :hex
      kw when is_list(kw) -> classify_kw(kw)
      _ -> :unknown
    end
  end

  defp classify_three(value_node, opts_node) do
    opts = unwrap(opts_node)
    value = unwrap(value_node)

    cond do
      is_list(opts) and has_path?(opts) -> :path
      is_list(opts) and has_git?(opts) -> :git
      is_binary(value) -> :hex
      true -> :unknown
    end
  end

  defp classify_kw(kw) do
    cond do
      has_path?(kw) -> :path
      has_git?(kw) -> :git
      true -> :unknown
    end
  end

  defp has_path?(kw), do: has_key?(kw, :path)
  defp has_git?(kw), do: has_key?(kw, :git) or has_key?(kw, :github)

  defp has_key?(kw, key) when is_list(kw) do
    Enum.any?(kw, fn
      {k, _v} -> unwrap(k) == key
      _ -> false
    end)
  end

  defp has_key?(_other, _key), do: false

  ## ─── Helpers ────────────────────────────────────────────────────────

  # Sourceror wraps literals in `{:__block__, meta, [literal]}` to carry trivia.
  defp unwrap({:__block__, _, [v]}), do: v
  defp unwrap(other), do: other

  defp render(ast) do
    Sourceror.to_string(ast)
  rescue
    _ -> "<unprintable>"
  end
end
