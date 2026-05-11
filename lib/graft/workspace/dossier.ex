defmodule Graft.Workspace.Dossier do
  @moduledoc """
  Read-only durable workspace status model.

  Summarises one active workspace/session without adding new orchestration
  behaviour. Missing optional data degrades to `:unknown` rather than
  crashing.
  """

  alias Graft.Workspace.HealthIssue

  @type status :: :healthy | :degraded | :unknown | :stale

  @type t :: %__MODULE__{
          workspace_id: String.t() | nil,
          repo_path: Path.t() | nil,
          project_name: String.t() | :unknown | nil,
          branch: String.t() | :unknown | nil,
          worktree_path: Path.t() | nil,
          tmux_session: String.t() | :unknown | nil,
          agent_metadata: map() | :unknown,
          git_summary: map(),
          last_activity_at: DateTime.t() | :unknown,
          health: [HealthIssue.t()] | nil,
          status: status(),
          attention_flags: [atom()],
          generated_at: DateTime.t()
        }

  defstruct [
    :workspace_id,
    :repo_path,
    :project_name,
    :branch,
    :worktree_path,
    :tmux_session,
    :agent_metadata,
    :git_summary,
    :last_activity_at,
    :health,
    :status,
    :attention_flags,
    :generated_at
  ]

  @doc """
  Convert a dossier to a JSON-safe map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d) do
    %{
      "workspace_id" => d.workspace_id,
      "repo_path" => d.repo_path,
      "project_name" => safe_string(d.project_name),
      "branch" => safe_string(d.branch),
      "worktree_path" => d.worktree_path,
      "tmux_session" => safe_string(d.tmux_session),
      "agent_metadata" => safe_map(d.agent_metadata),
      "git_summary" => stringify_keys(d.git_summary),
      "last_activity_at" => safe_datetime(d.last_activity_at),
      "health" => Enum.map(d.health || [], &health_to_map/1),
      "status" => safe_atom(d.status),
      "attention_flags" => Enum.map(d.attention_flags, &Atom.to_string/1),
      "generated_at" => DateTime.to_iso8601(d.generated_at)
    }
  end

  defp safe_string(:unknown), do: "unknown"
  defp safe_string(nil), do: nil
  defp safe_string(val) when is_binary(val), do: val

  defp safe_map(:unknown), do: %{"state" => "unknown"}
  defp safe_map(map) when is_map(map), do: map

  defp safe_datetime(:unknown), do: "unknown"
  defp safe_datetime(nil), do: nil
  defp safe_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp safe_atom(nil), do: nil
  defp safe_atom(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_atom(val), do: val

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp health_to_map(%HealthIssue{severity: sev, repo: repo, kind: kind, message: msg}) do
    %{
      "severity" => Atom.to_string(sev),
      "repo" => (repo && Atom.to_string(repo)) || nil,
      "kind" => Atom.to_string(kind),
      "message" => msg
    }
  end
end

defmodule Graft.Workspace.Dossier.Builder do
  @moduledoc """
  Boundary module that builds a `Dossier` from an existing
  `Graft.Workspace` snapshot.

  ## Subsystem ownership

  | Field | Source |
  |-------|--------|
  | `workspace_id` | `Workspace.Snapshot` |
  | `repo_path` / `worktree_path` | `Workspace.Snapshot` |
  | `project_name` | Builder (derived from root basename) |
  | `branch` | `GitState` (first git repo) |
  | `tmux_session` | Builder (`TMUX` env var) |
  | `agent_metadata` | Builder (`AGENT_PID` env var) |
  | `git_summary` | `GitState` (aggregated counts) |
  | `last_activity_at` | `Workspace.Snapshot` (`generated_at`) |
  | `health` | `Graft.Verify` / snapshot health list |
  | `status` | Builder (derived from topology + git) |
  | `attention_flags` | Builder (derived from topology + git) |
  | `generated_at` | Builder (`DateTime.utc_now/0`) |
  """

  alias Graft.Workspace
  alias Graft.Workspace.Dossier

  @spec build(Workspace.t()) :: Dossier.t()
  def build(%Workspace{} = snapshot) do
    %Dossier{
      workspace_id: snapshot.id,
      repo_path: snapshot.root,
      project_name: project_name(snapshot),
      branch: primary_branch(snapshot),
      worktree_path: snapshot.root,
      tmux_session: detect_tmux(),
      agent_metadata: detect_agent(),
      git_summary: git_summary(snapshot.git),
      last_activity_at: last_activity(snapshot),
      health: snapshot.health,
      status: derive_status(snapshot),
      attention_flags: derive_attention_flags(snapshot),
      generated_at: DateTime.utc_now()
    }
  end

  ## ─── Field derivation ───────────────────────────────────────────────

  defp project_name(%{root: nil}), do: :unknown

  defp project_name(%{root: root}) do
    root
    |> Path.basename()
    |> String.replace(~r/^workspace[_-]/i, "")
    |> case do
      "" -> :unknown
      name -> name
    end
  end

  defp primary_branch(%{git: []}), do: :unknown

  defp primary_branch(%{git: git}) do
    case Enum.find(git, & &1.is_git_repo?) do
      nil -> :unknown
      gs -> gs.branch || :unknown
    end
  end

  defp detect_tmux do
    case System.get_env("TMUX") do
      nil -> :unknown
      val -> val |> String.split(",") |> List.first() |> Path.basename()
    end
  end

  defp detect_agent do
    case {System.get_env("AGENT_PID"), System.get_env("AGENT_NAME")} do
      {nil, _} -> :unknown
      {pid, name} -> %{pid: pid, name: name || "unknown"}
    end
  end

  defp git_summary(git_states) when is_list(git_states) do
    %{
      repo_count: length(git_states),
      git_repos: Enum.count(git_states, & &1.is_git_repo?),
      dirty_count: Enum.count(git_states, & &1.dirty?),
      detached_count: Enum.count(git_states, & &1.detached_head?),
      ahead_total: Enum.sum(Enum.map(git_states, & &1.ahead)),
      behind_total: Enum.sum(Enum.map(git_states, & &1.behind)),
      in_progress_repos:
        Enum.flat_map(git_states, fn gs ->
          if gs.in_progress != :none and gs.is_git_repo? and gs.repo do
            [Atom.to_string(gs.repo)]
          else
            []
          end
        end)
    }
  end

  defp last_activity(%{generated_at: nil}), do: :unknown
  defp last_activity(%{generated_at: dt}), do: dt

  defp derive_status(%Workspace{topology: %{cyclic?: true}}), do: :degraded

  defp derive_status(%Workspace{git: []}), do: :unknown

  defp derive_status(%Workspace{git: git}) when is_list(git) do
    has_errors = Enum.any?(git, & &1.error)
    has_dirty_progress = Enum.any?(git, &(&1.dirty? and &1.in_progress != :none))

    cond do
      has_errors or has_dirty_progress -> :degraded
      true -> :healthy
    end
  end

  defp derive_status(_), do: :unknown

  defp derive_attention_flags(%Workspace{topology: topology, git: git}) do
    flags = []
    flags = if topology && topology.cyclic?, do: [:cyclic_dependencies | flags], else: flags

    Enum.reduce(git || [], flags, fn gs, acc ->
      acc = if gs.dirty?, do: [:uncommitted_changes | acc], else: acc
      acc = if gs.detached_head?, do: [:detached_head | acc], else: acc
      acc = if gs.ahead > 0 or gs.behind > 0, do: [:branch_divergence | acc], else: acc
      acc = if gs.in_progress != :none, do: [:in_progress | acc], else: acc
      acc = if gs.error, do: [:git_error | acc], else: acc
      acc
    end)
    |> Enum.uniq()
  end
end
