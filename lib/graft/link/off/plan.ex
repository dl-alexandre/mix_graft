defmodule Graft.Link.Off.Plan do
  @moduledoc """
  Plans a `link.off` operation: restore mix.exs files rewritten by a
  prior `link.on` run from the literal preimages recorded in
  `.graft/state.json`.

  Pure: filesystem reads only (no writes), no git, no Mix shell-outs.
  Mirrors the architecture of `Graft.Link.Plan` — the planner is the
  semantic authority; the runner is purely mechanical.

  ## Inputs

    * `workspace` — `Graft.Workspace` snapshot.
    * `state`    — `Graft.State{}` loaded via `Graft.State.load/1`.
    * `target_apps` — non-empty list of target atoms to unlink.

  ## Validation

    * Every target must appear as `target_app` of at least one entry in
      `state.entries`. Unknown targets raise `:off_target_not_in_state`.
    * Each matched entry's `repo` must still be a declared sibling, and
      its `repo_path` must lie inside `workspace.root`. Fence violations
      raise `:off_workspace_violation`.

  ## Determinism

  Restorations are sorted by `(repo, target_app)`. `affected_repos`
  and `remaining_target_apps` are sorted, deduped atom lists. Only
  `:generated_at` differs across runs.
  """

  alias Graft.{Error, State, Workspace}
  alias Graft.Link.Off.Plan.Restoration

  @type t :: %__MODULE__{
          operation: :link_off,
          generated_at: DateTime.t(),
          workspace_root: Path.t(),
          target_apps: [atom()],
          affected_repos: [atom()],
          restorations: [Restoration.t()],
          remaining_entries: [State.Entry.t()],
          remaining_target_apps: [atom()],
          warnings: [String.t()]
        }

  defstruct operation: :link_off,
            generated_at: nil,
            workspace_root: nil,
            target_apps: [],
            affected_repos: [],
            restorations: [],
            remaining_entries: [],
            remaining_target_apps: [],
            warnings: []

  @spec build(Workspace.t(), State.t(), [atom()]) :: {:ok, t()} | {:error, Error.t()}
  def build(%Workspace{} = workspace, %State{} = state, target_apps)
      when is_list(target_apps) do
    targets = target_apps |> Enum.uniq() |> Enum.sort()

    with :ok <- validate_targets_nonempty(targets),
         :ok <- validate_targets_in_state(targets, state),
         {to_restore, to_keep} = split_entries(state.entries, targets),
         :ok <- validate_workspace_fence(to_restore, workspace) do
      restorations =
        to_restore
        |> Enum.sort_by(&{Atom.to_string(&1.repo), Atom.to_string(&1.target_app)})
        |> Enum.map(&entry_to_restoration/1)

      affected_repos =
        restorations
        |> Enum.map(& &1.repo)
        |> Enum.uniq()
        |> Enum.sort()

      remaining_target_apps =
        to_keep
        |> Enum.map(& &1.target_app)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok,
       %__MODULE__{
         operation: :link_off,
         generated_at: DateTime.utc_now(),
         workspace_root: workspace.root,
         target_apps: targets,
         affected_repos: affected_repos,
         restorations: restorations,
         remaining_entries: to_keep,
         remaining_target_apps: remaining_target_apps,
         warnings: []
       }}
    end
  end

  ## ─── Validation ─────────────────────────────────────────────────────

  defp validate_targets_nonempty([]),
    do: {:error, Error.new(:plan_invalid_operation, "Target apps list must not be empty")}

  defp validate_targets_nonempty(_), do: :ok

  defp validate_targets_in_state(targets, %State{entries: entries}) do
    known = MapSet.new(entries, & &1.target_app)

    case Enum.reject(targets, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(
           :off_target_not_in_state,
           "Target app(s) have no recorded link in .graft/state.json: #{inspect(missing)}",
           %{targets: missing}
         )}
    end
  end

  defp validate_workspace_fence(entries, %Workspace{root: root, repos: repos}) do
    sibling_names = MapSet.new(repos, & &1.name)

    case Enum.find(entries, &fence_violation(&1, root, sibling_names)) do
      nil ->
        :ok

      bad ->
        reason =
          cond do
            not MapSet.member?(sibling_names, bad.repo) ->
              "repo #{inspect(bad.repo)} no longer declared in workspace"

            not inside_root?(bad.repo_path, root) ->
              "repo_path #{bad.repo_path} outside workspace root #{root}"

            not inside_root?(bad.mix_exs_path, root) ->
              "mix_exs_path #{bad.mix_exs_path} outside workspace root #{root}"
          end

        {:error,
         Error.new(
           :off_workspace_violation,
           "Refusing to restore #{inspect(bad.repo)}: #{reason}",
           %{
             repo: bad.repo,
             repo_path: bad.repo_path,
             mix_exs_path: bad.mix_exs_path,
             workspace_root: root
           }
         )}
    end
  end

  defp fence_violation(entry, root, sibling_names) do
    not MapSet.member?(sibling_names, entry.repo) or
      not inside_root?(entry.repo_path, root) or
      not inside_root?(entry.mix_exs_path, root)
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  ## ─── Splitting / projection ─────────────────────────────────────────

  defp split_entries(entries, targets) do
    target_set = MapSet.new(targets)

    Enum.reduce(entries, {[], []}, fn entry, {restore, keep} ->
      if MapSet.member?(target_set, entry.target_app) do
        {[entry | restore], keep}
      else
        {restore, [entry | keep]}
      end
    end)
    |> then(fn {r, k} -> {Enum.reverse(r), Enum.reverse(k)} end)
  end

  defp entry_to_restoration(entry) do
    %Restoration{
      repo: entry.repo,
      repo_path: entry.repo_path,
      target_app: entry.target_app,
      mix_exs_path: entry.mix_exs_path,
      mix_exs_before_hash: entry.mix_exs_before_hash,
      mix_exs_after_hash: entry.mix_exs_after_hash,
      preimage: entry.preimage,
      replacement: entry.replacement
    }
  end
end
