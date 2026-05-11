defmodule Graft.Link.Plan do
  @moduledoc """
  Computes the exact mutation plan for a `link.on` operation across a
  Graft workspace. Pure: filesystem reads only (no writes), no git,
  no Mix shell-outs.

  ## Closure semantics

  Linking a target app `T` cascades through the sibling dependency graph:

    1. Every sibling that depends on `T` gets a change pair `(sibling, T)`.
    2. Each such sibling is itself now treated as a linked app — so any
       *further* sibling depending on it also gets a change pair.
    3. The expansion repeats until no new pairs are added.

  Cycles in the sibling graph terminate naturally: once a pair has been
  recorded once it is not re-added.

  ## Determinism

  Given identical `(workspace, target_apps, opts)` input, `build/3`
  returns a plan whose `target_apps`, `affected_repos`, and `changes`
  are byte-stable. Only `:generated_at` differs across runs.

  ## Workspace fence

  Plans never include changes for repos that are not declared in
  `graft.exs`. The closure walks only `workspace.deps`, which by
  construction (`Workspace.snapshot/1`) covers only manifest siblings.
  Targets outside the workspace are rejected with a structured error.

  ## v0.1 scope

  Only `:operation, :link_on` is implementable here. `:link_off` planning
  awaits the state-file milestone (`Graft.State`) since revert requires
  recorded preimages.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.Repo
  alias Graft.Link.{Plan.Change, RewriteResult, Rewriter}

  @type operation :: :link_on | :link_off

  @type t :: %__MODULE__{
          operation: operation(),
          generated_at: DateTime.t(),
          workspace_root: Path.t(),
          target_apps: [atom()],
          affected_repos: [atom()],
          changes: [Change.t()],
          warnings: [String.t()]
        }

  defstruct [
    :operation,
    :generated_at,
    :workspace_root,
    target_apps: [],
    affected_repos: [],
    changes: [],
    warnings: []
  ]

  @doc """
  Build a link plan for `target_apps` against `workspace`.

  Options:

    * `:operation` — `:link_on` (default) or `:link_off`. `:link_off` is
      not yet implementable and returns a structured `:not_implemented`
      error.
  """
  @spec build(Workspace.t(), [atom()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def build(%Workspace{} = workspace, target_apps, opts \\ [])
      when is_list(target_apps) and is_list(opts) do
    operation = Keyword.get(opts, :operation, :link_on)

    with :ok <- validate_operation(operation),
         :ok <- validate_targets(workspace, target_apps) do
      build_plan(workspace, Enum.sort(Enum.uniq(target_apps)), operation)
    end
  end

  ## ─── Validation ─────────────────────────────────────────────────────

  defp validate_operation(:link_on), do: :ok

  defp validate_operation(:link_off) do
    {:error,
     Error.new(
       :not_implemented,
       "link.off planning awaits the state-file milestone; not yet supported"
     )}
  end

  defp validate_operation(other) do
    {:error,
     Error.new(
       :plan_invalid_operation,
       "Unknown operation #{inspect(other)} (expected :link_on or :link_off)",
       %{operation: other}
     )}
  end

  defp validate_targets(_workspace, []) do
    {:error, Error.new(:plan_invalid_operation, "Target apps list must not be empty")}
  end

  defp validate_targets(workspace, target_apps) do
    sibling_names = MapSet.new(workspace.repos, & &1.name)

    case Enum.reject(target_apps, &MapSet.member?(sibling_names, &1)) do
      [] ->
        :ok

      bad ->
        {:error,
         Error.new(
           :plan_target_not_in_workspace,
           "Target app(s) not declared as siblings in graft.exs: #{inspect(bad)}",
           %{targets: bad}
         )}
    end
  end

  ## ─── Plan construction ─────────────────────────────────────────────

  defp build_plan(workspace, target_apps, operation) do
    pairs =
      workspace.deps
      |> closure(MapSet.new(target_apps))
      |> Enum.sort()

    {changes, warnings} = collect_changes(workspace, pairs)

    affected_repos =
      changes
      |> Enum.map(& &1.repo)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok,
     %__MODULE__{
       operation: operation,
       generated_at: DateTime.utc_now(),
       workspace_root: workspace.root,
       target_apps: target_apps,
       affected_repos: affected_repos,
       changes: changes,
       warnings: warnings
     }}
  end

  ## ─── Closure ────────────────────────────────────────────────────────

  # Returns a deduped list of `{consumer_repo_atom, target_app_atom}`
  # pairs covering the full transitive impact of linking `target_apps`.
  defp closure(deps, target_apps) do
    consumers_of =
      deps
      |> Enum.group_by(& &1.app, & &1.repo)
      |> Map.new(fn {app, repos} -> {app, Enum.uniq(repos)} end)

    expand(consumers_of, target_apps, [])
  end

  defp expand(consumers_of, linked, pairs) do
    new_pairs =
      linked
      |> Enum.flat_map(fn app ->
        Enum.map(Map.get(consumers_of, app, []), &{&1, app})
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in pairs))

    case new_pairs do
      [] ->
        pairs

      _ ->
        new_linked_apps = MapSet.new(new_pairs, fn {consumer, _} -> consumer end)
        expand(consumers_of, MapSet.union(linked, new_linked_apps), pairs ++ new_pairs)
    end
  end

  ## ─── Per-pair change construction ──────────────────────────────────

  defp collect_changes(workspace, pairs) do
    {changes_rev, warnings_rev} =
      Enum.reduce(pairs, {[], []}, fn pair, {changes, warnings} ->
        case build_change(workspace, pair) do
          {:ok, change} -> {[change | changes], warnings}
          {:skip, warning} -> {changes, [warning | warnings]}
        end
      end)

    {Enum.reverse(changes_rev), Enum.reverse(warnings_rev)}
  end

  defp build_change(workspace, {consumer_atom, dep_atom}) do
    consumer = find_repo(workspace, consumer_atom)
    target = find_repo(workspace, dep_atom)

    cond do
      is_nil(consumer) ->
        {:skip, "Consumer repo #{inspect(consumer_atom)} is not declared in the workspace"}

      is_nil(target) ->
        {:skip, "Target #{inspect(dep_atom)} is not declared in the workspace"}

      not consumer.exists? ->
        {:skip, "Skipping #{inspect(consumer_atom)}: directory not present on disk"}

      not consumer.has_mix_exs? ->
        {:skip, "Skipping #{inspect(consumer_atom)}: no mix.exs present"}

      true ->
        do_build_change(consumer, target)
    end
  end

  defp do_build_change(%Repo{} = consumer, %Repo{} = target) do
    mix_exs_path = Path.join(consumer.absolute_path, "mix.exs")

    case File.read(mix_exs_path) do
      {:ok, contents} ->
        rewrite_and_build(consumer, target, contents)

      {:error, reason} ->
        {:skip, "Could not read #{mix_exs_path}: #{inspect(reason)}"}
    end
  end

  defp rewrite_and_build(consumer, target, contents) do
    relative = relative_sibling_path(consumer.absolute_path, target.absolute_path)

    case Rewriter.rewrite(contents, target.name, path: relative) do
      {:ok, %RewriteResult{matched_dep?: true} = result} ->
        change = %Change{
          repo: consumer.name,
          repo_path: consumer.absolute_path,
          target_app: target.name,
          dependency_source_before: render_dep_ast(result.original_dep_ast),
          dependency_source_after: render_dep_ast(result.rewritten_dep_ast),
          mix_exs_before_hash: sha256(contents),
          proposed_mix_exs_after_hash: sha256(result.rewritten_contents),
          changed?: result.changed?
        }

        {:ok, change}

      {:ok, %RewriteResult{matched_dep?: false}} ->
        {:skip,
         "Skipping #{inspect(consumer.name)}: no #{inspect(target.name)} dep found in mix.exs (parser/rewriter disagreement)"}

      {:error, %Error{message: msg}} ->
        {:skip,
         "Skipping #{inspect(consumer.name)}: rewriter error for #{inspect(target.name)} — #{msg}"}
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp find_repo(workspace, name), do: Enum.find(workspace.repos, &(&1.name == name))

  # Compute a relative POSIX path from `from_dir` to `to_dir`. Both must
  # be absolute. Sibling repos under a common workspace root produce
  # results like "../req_llm".
  defp relative_sibling_path(from_dir, to_dir) do
    from_parts = Path.split(from_dir)
    to_parts = Path.split(to_dir)

    common = common_prefix_length(from_parts, to_parts)
    ups = List.duplicate("..", length(from_parts) - common)
    rest = Enum.drop(to_parts, common)

    case ups ++ rest do
      [] -> "."
      parts -> Path.join(parts)
    end
  end

  defp common_prefix_length([h | t1], [h | t2]), do: 1 + common_prefix_length(t1, t2)
  defp common_prefix_length(_, _), do: 0

  defp render_dep_ast(nil), do: nil
  defp render_dep_ast(ast), do: Sourceror.to_string(ast)

  defp sha256(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  end
end
