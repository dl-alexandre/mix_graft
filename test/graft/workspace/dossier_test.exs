defmodule Graft.Workspace.DossierTest do
  use ExUnit.Case

  alias Graft.Workspace
  alias Graft.Workspace.{Dossier, Repo, Dependency, HealthIssue}
  alias Graft.GitState

  defp sample_snapshot do
    %Workspace{
      id: "ws-1",
      schema_version: 1,
      root: "/tmp/oss_workspace",
      generated_at: ~U[2024-01-01T00:00:00Z],
      repos: [
        %Repo{
          name: :alpha,
          path: "alpha",
          absolute_path: "/tmp/oss_workspace/alpha",
          exists?: true,
          has_mix_exs?: true
        },
        %Repo{
          name: :beta,
          path: "beta",
          absolute_path: "/tmp/oss_workspace/beta",
          exists?: true,
          has_mix_exs?: true
        }
      ],
      deps: [
        %Dependency{repo: :alpha, app: :beta, raw: "{:beta, \"~> 1.0\"}", source: :hex}
      ],
      git: [
        %GitState{
          repo: :alpha,
          repo_path: "/tmp/oss_workspace/alpha",
          is_git_repo?: true,
          branch: "main",
          dirty?: false,
          ahead: 0,
          behind: 0,
          in_progress: :none,
          error: nil
        },
        %GitState{
          repo: :beta,
          repo_path: "/tmp/oss_workspace/beta",
          is_git_repo?: true,
          branch: "feature",
          dirty?: true,
          ahead: 2,
          behind: 1,
          in_progress: :none,
          error: nil
        }
      ],
      topology: %Workspace.Topology{
        consumers: %{beta: [:alpha]},
        providers: %{alpha: [:beta]},
        transitive_dependents: %{alpha: MapSet.new([:beta]), beta: MapSet.new([])},
        topological_order: [:beta, :alpha],
        external_apps: [],
        cyclic?: false
      },
      health: [
        %HealthIssue{severity: :info, repo: :alpha, kind: :outdated_dep, message: "foo is old"}
      ]
    }
  end

  describe "Builder.build/1" do
    test "populates all dossier fields from a snapshot" do
      dossier = Dossier.Builder.build(sample_snapshot())

      assert dossier.workspace_id == "ws-1"
      assert dossier.repo_path == "/tmp/oss_workspace"
      assert dossier.project_name == "oss_workspace"
      assert dossier.branch == "main"
      assert dossier.worktree_path == "/tmp/oss_workspace"
      assert dossier.tmux_session == :unknown or is_binary(dossier.tmux_session)
      assert dossier.agent_metadata == :unknown or is_map(dossier.agent_metadata)
      assert dossier.last_activity_at == ~U[2024-01-01T00:00:00Z]
      assert dossier.status == :healthy
      assert %DateTime{} = dossier.generated_at
    end

    test "derives correct git summary" do
      dossier = Dossier.Builder.build(sample_snapshot())
      summary = dossier.git_summary

      assert summary.repo_count == 2
      assert summary.git_repos == 2
      assert summary.dirty_count == 1
      assert summary.detached_count == 0
      assert summary.ahead_total == 2
      assert summary.behind_total == 1
      assert summary.in_progress_repos == []
    end

    test "includes health issues" do
      dossier = Dossier.Builder.build(sample_snapshot())
      assert length(dossier.health) == 1
      assert hd(dossier.health).kind == :outdated_dep
    end

    test "flags attention items" do
      dossier = Dossier.Builder.build(sample_snapshot())

      assert :uncommitted_changes in dossier.attention_flags
      assert :branch_divergence in dossier.attention_flags
      refute :cyclic_dependencies in dossier.attention_flags
      refute :git_error in dossier.attention_flags
    end
  end

  describe "degraded / unknown data" do
    test "degrades missing data to unknown without crashing" do
      minimal = %Workspace{
        id: "ws-min",
        schema_version: 1,
        root: nil,
        generated_at: nil,
        repos: [],
        deps: [],
        git: [],
        topology: nil,
        health: []
      }

      dossier = Dossier.Builder.build(minimal)

      assert dossier.workspace_id == "ws-min"
      assert dossier.project_name == :unknown
      assert dossier.branch == :unknown
      assert dossier.last_activity_at == :unknown
      assert dossier.status == :unknown
      assert dossier.attention_flags == []
      assert dossier.git_summary.repo_count == 0
    end

    test "marks degraded when topology is cyclic" do
      cyclic = %Workspace{
        id: "ws-cyclic",
        schema_version: 1,
        root: "/tmp/ws",
        generated_at: ~U[2024-01-01T00:00:00Z],
        repos: [],
        deps: [],
        git: [],
        topology: %Workspace.Topology{
          consumers: %{},
          providers: %{},
          transitive_dependents: %{},
          topological_order: [],
          external_apps: [],
          cyclic?: true
        },
        health: []
      }

      dossier = Dossier.Builder.build(cyclic)
      assert dossier.status == :degraded
      assert :cyclic_dependencies in dossier.attention_flags
    end
  end

  describe "to_map/1" do
    test "produces JSON-safe values" do
      dossier = Dossier.Builder.build(sample_snapshot())
      map = Dossier.to_map(dossier)

      assert is_binary(map["workspace_id"])
      assert is_binary(map["project_name"])
      assert is_binary(map["status"])
      assert is_list(map["attention_flags"])
      assert Enum.all?(map["attention_flags"], &is_binary/1)
      assert is_binary(map["generated_at"])
      assert is_binary(map["last_activity_at"])
      assert is_map(map["git_summary"])
      assert map["git_summary"]["repo_count"] == 2
      assert map["git_summary"]["dirty_count"] == 1
      assert map["git_summary"]["ahead_total"] == 2
    end

    test "handles unknown values as strings" do
      minimal = %Workspace{
        id: "ws-min",
        schema_version: 1,
        root: nil,
        generated_at: nil,
        repos: [],
        deps: [],
        git: [],
        topology: nil,
        health: []
      }

      dossier = Dossier.Builder.build(minimal)
      map = Dossier.to_map(dossier)

      assert map["project_name"] == "unknown"
      assert map["branch"] == "unknown"
      assert map["tmux_session"] == "unknown" or is_binary(map["tmux_session"])
      assert map["agent_metadata"] == %{"state" => "unknown"}
      assert map["last_activity_at"] == "unknown"
      assert map["status"] == "unknown"
    end
  end
end
