defmodule Graft.PlanTest do
  use ExUnit.Case

  alias Graft.Workspace
  alias Graft.Workspace.{Repo, Dependency}

  defp sample_workspace do
    %Workspace{
      id: "ws-1",
      schema_version: 1,
      root: "/tmp",
      generated_at: ~U[2024-01-01T00:00:00Z],
      repos: [
        %Repo{name: :a, path: "a", absolute_path: "/tmp/a", exists?: true, has_mix_exs?: true},
        %Repo{name: :b, path: "b", absolute_path: "/tmp/b", exists?: true, has_mix_exs?: true}
      ],
      deps: [
        %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex}
      ],
      git: []
    }
  end

  test "from_diff creates a plan with operations" do
    current = sample_workspace()

    desired = %{
      current
      | id: "ws-2",
        repos: [
          %Repo{name: :a, path: "a", absolute_path: "/tmp/a", exists?: true, has_mix_exs?: true},
          %Repo{name: :b, path: "b", absolute_path: "/tmp/b", exists?: true, has_mix_exs?: true},
          %Repo{name: :c, path: "c", absolute_path: "/tmp/c", exists?: true, has_mix_exs?: true}
        ]
    }

    plan = Graft.Plan.from_diff(current, desired)

    assert plan.action == :attach
    assert plan.status == :planned
    assert plan.current.id == "ws-1"
    assert plan.desired.id == "ws-2"
    assert is_list(plan.operations)
    assert is_list(plan.rollback)
    assert length(plan.preconditions) > 0
  end

  test "noop plan has no operations" do
    current = sample_workspace()
    plan = Graft.Plan.from_diff(current, current)

    assert Graft.Plan.noop?(plan)
    assert plan.operations == []
  end

  test "verify passes when preconditions hold" do
    current = sample_workspace()
    plan = Graft.Plan.from_diff(current, current)

    assert {:ok, verified} = Graft.Plan.verify(plan)
    assert verified.status == :verified
  end
end
