defmodule Graft.Workspace.Diff do
  @moduledoc """
  Compare two workspace snapshots and produce a structural delta.

  The diff is **declarative**: it describes what changed, not how to
  effect the change. That is the job of `Graft.Plan`.

  ## Design

  * Two snapshots taken at different times, or a snapshot vs a desired state.
  * Produces a `Delta` with `:added`, `:removed`, `:changed`, `:same` buckets.
  * Each entry is a path + before + after value (or nil for additions/removals).

  ## Use cases

  * `dry-run` previews: "what would link.on do to the workspace?"
  * Drift detection: "has the workspace changed since last snapshot?"
  * Plan generation: `Graft.Plan.from_delta/2`
  * Audit logging: append-only delta log
  """

  alias Graft.Workspace

  defmodule Delta do
    @moduledoc "A structural diff between two workspace snapshots."

    @type entry :: %{
            path: [atom() | String.t()],
            before: any(),
            after: any()
          }

    @type t :: %__MODULE__{
            from_id: String.t(),
            to_id: String.t(),
            generated_at: DateTime.t(),
            added: [entry()],
            removed: [entry()],
            changed: [entry()],
            same: [entry()]
          }

    defstruct [:from_id, :to_id, :generated_at, added: [], removed: [], changed: [], same: []]
  end

  alias Graft.Workspace

  defmodule Delta do
    @moduledoc "A structural diff between two workspace snapshots."

    @type entry :: %{
            path: [atom() | String.t()],
            before: any(),
            after: any()
          }

    @type t :: %__MODULE__{
            from_id: String.t(),
            to_id: String.t(),
            generated_at: DateTime.t(),
            added: [entry()],
            removed: [entry()],
            changed: [entry()],
            same: [entry()]
          }

    defstruct [:from_id, :to_id, :generated_at, added: [], removed: [], changed: [], same: []]
  end

  @doc """
  Diff two workspace snapshots.

  Returns a `Delta` describing every structural change.
  """
  @spec diff(Workspace.t(), Workspace.t()) :: Delta.t()
  def diff(%Workspace{} = before, %Workspace{} = after_snapshot) do
    repos_delta = diff_repos(before.repos, after_snapshot.repos)
    deps_delta = diff_deps(before.deps, after_snapshot.deps)
    links_delta = diff_links(before.links, after_snapshot.links)
    git_delta = diff_git(before.git, after_snapshot.git)

    all_entries = repos_delta ++ deps_delta ++ links_delta ++ git_delta

    {added, rest} = Enum.split_with(all_entries, &(&1.before == nil and &1.after != nil))
    {removed, rest} = Enum.split_with(rest, &(&1.before != nil and &1.after == nil))
    {changed, same} = Enum.split_with(rest, &(&1.before != &1.after))

    %Delta{
      from_id: before.id,
      to_id: after_snapshot.id,
      generated_at: DateTime.utc_now(),
      added: added,
      removed: removed,
      changed: changed,
      same: same
    }
  end

  @doc """
  True iff the delta contains no added, removed, or changed entries.
  """
  @spec empty?(Delta.t()) :: boolean()
  def empty?(%Delta{added: [], removed: [], changed: []}), do: true
  def empty?(_), do: false

  @doc """
  Return only entries affecting a specific repo.
  """
  @spec for_repo(Delta.t(), atom()) :: [Delta.entry()]
  def for_repo(%Delta{} = delta, repo_name) do
    (delta.added ++ delta.removed ++ delta.changed)
    |> Enum.filter(fn entry ->
      repo_in_path?(entry.path, repo_name)
    end)
  end

  ## ─── Repo diff ──────────────────────────────────────────────────────

  defp diff_repos(before_repos, after_snapshot_repos) do
    before_map = Map.new(before_repos, &{&1.name, &1})
    after_map = Map.new(after_snapshot_repos, &{&1.name, &1})

    all_keys = (Map.keys(before_map) ++ Map.keys(after_map)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(all_keys, fn name ->
      b = Map.get(before_map, name)
      a = Map.get(after_map, name)

      cond do
        is_nil(b) ->
          [%{path: [:repos, name], before: nil, after: a}]

        is_nil(a) ->
          [%{path: [:repos, name], before: b, after: nil}]

        b != a ->
          diff_repo_fields(name, b, a)

        true ->
          [%{path: [:repos, name], before: b, after: a}]
      end
    end)
  end

  defp diff_repo_fields(name, before, after_val) do
    fields = [:path, :absolute_path, :exists?, :has_mix_exs?]

    Enum.flat_map(fields, fn field ->
      b = Map.get(before, field)
      a = Map.get(after_val, field)

      if b != a do
        [%{path: [:repos, name, field], before: b, after: a}]
      else
        []
      end
    end)
  end

  ## ─── Dep diff ───────────────────────────────────────────────────────

  defp diff_deps(before_deps, after_snapshot_deps) do
    before_map = index_deps(before_deps)
    after_map = index_deps(after_snapshot_deps)

    all_keys = (Map.keys(before_map) ++ Map.keys(after_map)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(all_keys, fn key ->
      b = Map.get(before_map, key)
      a = Map.get(after_map, key)

      cond do
        is_nil(b) -> [%{path: [:deps, key], before: nil, after: a}]
        is_nil(a) -> [%{path: [:deps, key], before: b, after: nil}]
        b != a -> [%{path: [:deps, key], before: b, after: a}]
        true -> [%{path: [:deps, key], before: b, after: a}]
      end
    end)
  end

  defp index_deps(deps) do
    Map.new(deps, &{{&1.repo, &1.app}, &1})
  end

  ## ─── Link diff ──────────────────────────────────────────────────────

  defp diff_links(before_links, after_snapshot_links) do
    before_map = index_links(before_links)
    after_map = index_links(after_snapshot_links)

    all_keys = (Map.keys(before_map) ++ Map.keys(after_map)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(all_keys, fn key ->
      b = Map.get(before_map, key)
      a = Map.get(after_map, key)

      cond do
        is_nil(b) -> [%{path: [:links, key], before: nil, after: a}]
        is_nil(a) -> [%{path: [:links, key], before: b, after: nil}]
        b != a -> [%{path: [:links, key], before: b, after: a}]
        true -> [%{path: [:links, key], before: b, after: a}]
      end
    end)
  end

  defp index_links(links) do
    Map.new(links, &{{&1.repo, &1.dep}, &1})
  end

  ## ─── Git state diff ─────────────────────────────────────────────────

  defp diff_git(before_git, after_snapshot_git) do
    before_map = Map.new(before_git, &{&1.repo, &1})
    after_map = Map.new(after_snapshot_git, &{&1.repo, &1})

    all_keys = (Map.keys(before_map) ++ Map.keys(after_map)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(all_keys, fn name ->
      b = Map.get(before_map, name)
      a = Map.get(after_map, name)

      cond do
        is_nil(b) ->
          [%{path: [:git, name], before: nil, after: a}]

        is_nil(a) ->
          [%{path: [:git, name], before: b, after: nil}]

        b != a ->
          diff_git_fields(name, b, a)

        true ->
          []
      end
    end)
  end

  defp diff_git_fields(name, before, after_val) do
    fields = [:branch, :head_sha, :upstream, :ahead, :behind, :dirty?, :in_progress, :error]

    Enum.flat_map(fields, fn field ->
      b = Map.get(before, field)
      a = Map.get(after_val, field)

      if b != a do
        [%{path: [:git, name, field], before: b, after: a}]
      else
        []
      end
    end)
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp repo_in_path?([:repos, repo | _], repo), do: true
  defp repo_in_path?([:deps, {repo, _} | _], repo), do: true
  defp repo_in_path?([:links, {repo, _} | _], repo), do: true
  defp repo_in_path?([:git, repo | _], repo), do: true
  defp repo_in_path?(_, _), do: false
end
