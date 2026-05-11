defmodule Graft.Workspace.TopologyTest do
  use ExUnit.Case

  alias Graft.Workspace.{Repo, Dependency, Topology}

  defp repo(name, opts \\ []) do
    %Repo{
      name: name,
      path: Atom.to_string(name),
      absolute_path: "/tmp/#{name}",
      exists?: Keyword.get(opts, :exists?, true),
      has_mix_exs?: true
    }
  end

  defp dep(repo, app) do
    %Dependency{repo: repo, app: app, raw: "#{app}", source: :hex}
  end

  test "from_workspace builds consumer and provider maps" do
    repos = [repo(:a), repo(:b), repo(:c)]
    deps = [dep(:a, :b), dep(:b, :c)]

    topology = Topology.from_workspace(%Graft.Workspace{repos: repos, deps: deps})

    assert topology.consumers[:b] == [:a]
    assert topology.consumers[:c] == [:b]
    assert topology.providers[:a] == [:b]
    assert topology.providers[:b] == [:c]
  end

  test "link_closure returns transitive pairs" do
    repos = [repo(:a), repo(:b), repo(:c)]
    deps = [dep(:a, :b), dep(:b, :c)]

    topology = Topology.from_workspace(%Graft.Workspace{repos: repos, deps: deps})
    closure = Topology.link_closure(topology, [:c])

    assert {nil, :c} not in closure
    assert {:b, :c} in closure
    assert {:a, :b} in closure
  end

  test "topological_order respects dependency direction" do
    repos = [repo(:a), repo(:b), repo(:c)]
    deps = [dep(:a, :b), dep(:b, :c)]

    topology = Topology.from_workspace(%Graft.Workspace{repos: repos, deps: deps})

    # c has no dependents, so it should be first (or early)
    # a depends on b which depends on c, so a should be last
    idx_c = Enum.find_index(topology.topological_order, &(&1 == :c))
    idx_b = Enum.find_index(topology.topological_order, &(&1 == :b))
    idx_a = Enum.find_index(topology.topological_order, &(&1 == :a))

    assert idx_c < idx_b
    assert idx_b < idx_a
  end

  test "detects cycles" do
    repos = [repo(:a), repo(:b)]
    deps = [dep(:a, :b), dep(:b, :a)]

    topology = Topology.from_workspace(%Graft.Workspace{repos: repos, deps: deps})

    assert topology.cyclic? == true
  end

  test "identifies external apps" do
    repos = [repo(:a)]
    deps = [dep(:a, :external_app)]

    topology = Topology.from_workspace(%Graft.Workspace{repos: repos, deps: deps})

    assert :external_app in topology.external_apps
  end
end
