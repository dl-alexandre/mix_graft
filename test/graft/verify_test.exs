defmodule Graft.VerifyTest do
  use ExUnit.Case

  alias Graft.Workspace
  alias Graft.Workspace.{Repo, Dependency, Topology}
  alias Graft.GitState

  defp clean_workspace do
    repos = [
      %Repo{
        name: :a,
        path: "a",
        absolute_path: "/workspace/a",
        exists?: true,
        has_mix_exs?: true
      },
      %Repo{
        name: :b,
        path: "b",
        absolute_path: "/workspace/b",
        exists?: true,
        has_mix_exs?: true
      },
      %Repo{name: :c, path: "c", absolute_path: "/workspace/c", exists?: true, has_mix_exs?: true}
    ]

    deps = [
      %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex},
      %Dependency{repo: :b, app: :c, raw: "{:c, \"~> 1.0\"}", source: :hex}
    ]

    workspace = %Workspace{
      id: "test",
      schema_version: 1,
      root: "/workspace",
      generated_at: ~U[2024-01-01T00:00:00Z],
      repos: repos,
      deps: deps,
      git: [
        %GitState{
          repo: :a,
          repo_path: "/workspace/a",
          is_git_repo?: true,
          branch: "main",
          dirty?: false
        },
        %GitState{
          repo: :b,
          repo_path: "/workspace/b",
          is_git_repo?: true,
          branch: "main",
          dirty?: false
        }
      ],
      links: []
    }

    topology = Topology.from_workspace(workspace)
    %{workspace | topology: topology}
  end

  test "passes for clean workspace" do
    workspace = clean_workspace()
    violations = Graft.Verify.check(workspace)

    assert Graft.Verify.pass?(violations)
    # No fatal or error violations — warnings/info about external apps and
    # missing .graft/backups are expected
    refute Enum.any?(violations, &(&1.severity in [:fatal, :error]))
  end

  test "detects cyclic dependencies" do
    workspace = clean_workspace()

    cyclic_deps = [
      %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex},
      %Dependency{repo: :b, app: :a, raw: "{:a, \"~> 1.0\"}", source: :hex}
    ]

    workspace = %{workspace | deps: cyclic_deps}
    workspace = %{workspace | topology: Topology.from_workspace(workspace)}
    violations = Graft.Verify.check(workspace)

    refute Graft.Verify.pass?(violations)
    assert Enum.any?(violations, &(&1.invariant == "no_cycles" and &1.severity == :fatal))
  end

  test "detects repo escaping workspace root" do
    workspace = clean_workspace()

    bad_repo = %Repo{
      name: :evil,
      path: "evil",
      absolute_path: "/outside/e",
      exists?: true,
      has_mix_exs?: true
    }

    workspace = %{workspace | repos: [bad_repo | workspace.repos]}

    violations = Graft.Verify.check(workspace)

    refute Graft.Verify.pass?(violations)

    assert Enum.any?(
             violations,
             &(&1.invariant == "graft_root_confinement" and &1.severity == :fatal)
           )
  end

  test "detects dirty git repos" do
    workspace = clean_workspace()

    dirty_git = [
      %GitState{
        repo: :a,
        repo_path: "/workspace/a",
        is_git_repo?: true,
        branch: "main",
        dirty?: true
      }
    ]

    workspace = %{workspace | git: dirty_git}

    violations = Graft.Verify.check(workspace)

    assert Enum.any?(
             violations,
             &(&1.invariant == "local_modifications" and &1.severity == :warning)
           )
  end

  test "detects detached HEAD" do
    workspace = clean_workspace()

    detached = [
      %GitState{repo: :a, repo_path: "/workspace/a", is_git_repo?: true, detached_head?: true}
    ]

    workspace = %{workspace | git: detached}

    violations = Graft.Verify.check(workspace)

    assert Enum.any?(violations, &(&1.invariant == "detached_heads" and &1.severity == :warning))
  end

  test "detects branch divergence" do
    workspace = clean_workspace()

    diverged = [
      %GitState{
        repo: :a,
        repo_path: "/workspace/a",
        is_git_repo?: true,
        upstream: "origin/main",
        ahead: 2,
        behind: 3
      }
    ]

    workspace = %{workspace | git: diverged}

    violations = Graft.Verify.check(workspace)

    refute Graft.Verify.pass?(violations)
    assert Enum.any?(violations, &(&1.invariant == "branch_divergence" and &1.severity == :error))
  end

  test "detects path traversal" do
    workspace = clean_workspace()

    bad_repo = %Repo{
      name: :x,
      path: "../outside",
      absolute_path: "/workspace/../outside",
      exists?: false,
      has_mix_exs?: false
    }

    workspace = %{workspace | repos: [bad_repo | workspace.repos]}

    violations = Graft.Verify.check(workspace)

    refute Graft.Verify.pass?(violations)
    assert Enum.any?(violations, &(&1.invariant == "no_path_traversal" and &1.severity == :fatal))
  end

  test "detects missing topology" do
    workspace = %{clean_workspace() | topology: nil}
    violations = Graft.Verify.check(workspace)

    refute Graft.Verify.pass?(violations)
    assert Enum.any?(violations, &(&1.invariant == "topology_computed" and &1.severity == :fatal))
  end

  test "report formats violations by severity" do
    workspace = clean_workspace()
    # Add a cycle to get multiple severities
    cyclic_deps = [
      %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex},
      %Dependency{repo: :b, app: :a, raw: "{:a, \"~> 1.0\"}", source: :hex}
    ]

    workspace = %{workspace | deps: cyclic_deps}
    workspace = %{workspace | topology: Topology.from_workspace(workspace)}
    violations = Graft.Verify.check(workspace)
    report = Graft.Verify.report(violations)

    assert String.contains?(report, "FATAL:")
    assert String.contains?(report, "no_cycles")
  end
end
