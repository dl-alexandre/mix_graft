defmodule Graft.Link.PlanTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Link.Plan
  alias Graft.Link.Plan.Change

  @moduletag :tmp_dir

  describe "build/3 — direct dependency planning" do
    test "produces one change per direct consumer of the target", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:ok, plan} = Plan.build(ws, [:req_llm])

      assert plan.operation == :link_on
      assert plan.target_apps == [:req_llm]
      assert plan.workspace_root == Path.expand(tmp_dir)
      assert plan.affected_repos == [:jido_ai, :jido_chat]
      assert length(plan.changes) == 2
      assert Enum.all?(plan.changes, &(&1.target_app == :req_llm))
      assert Enum.all?(plan.changes, & &1.changed?)
      assert plan.warnings == []
    end

    test "Change carries before/after hashes and dep source strings",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      [change] = plan.changes

      assert %Change{
               repo: :jido_ai,
               target_app: :req_llm,
               changed?: true
             } = change

      assert change.repo_path == Path.expand(Path.join(tmp_dir, "jido_ai"))
      assert change.dependency_source_before =~ ~s|"~> 1.0"|
      assert change.dependency_source_after =~ ~s|path: "../req_llm"|
      assert byte_size(change.mix_exs_before_hash) == 64
      assert byte_size(change.proposed_mix_exs_after_hash) == 64
      assert change.mix_exs_before_hash != change.proposed_mix_exs_after_hash
    end
  end

  describe "build/3 — transitive dependency planning" do
    test "cascades through the sibling graph", %{tmp_dir: tmp_dir} do
      # req_llm <- jido_ai <- jido
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido, [{:jido_ai, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert plan.affected_repos == [:jido, :jido_ai]

      pairs = Enum.map(plan.changes, &{&1.repo, &1.target_app}) |> Enum.sort()
      assert pairs == [{:jido, :jido_ai}, {:jido_ai, :req_llm}]
    end

    test "terminates on cycles in the sibling graph", %{tmp_dir: tmp_dir} do
      # a <-> b cycle
      build_workspace(tmp_dir, [
        {:a, [{:b, "~> 1.0"}]},
        {:b, [{:a, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:a])

      pairs = Enum.map(plan.changes, &{&1.repo, &1.target_app}) |> Enum.sort()
      assert pairs == [{:a, :b}, {:b, :a}]
      assert plan.affected_repos == [:a, :b]
    end
  end

  describe "build/3 — workspace fence enforcement" do
    test "rejects targets that are not declared as siblings", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])

      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :plan_target_not_in_workspace, details: %{targets: bad}}} =
               Plan.build(ws, [:not_a_sibling])

      assert :not_a_sibling in bad
    end

    test "with mixed valid and invalid targets, rejects the whole call",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :plan_target_not_in_workspace, details: %{targets: bad}}} =
               Plan.build(ws, [:foo, :outside])

      assert bad == [:outside]
    end

    test "external (non-sibling) deps in consumer mix.exs do not contaminate the plan",
         %{tmp_dir: tmp_dir} do
      # jido_ai depends on req_llm (sibling) AND on credo (external).
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}, {:credo, "~> 1.7"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert Enum.all?(plan.changes, &(&1.target_app == :req_llm))
      refute Enum.any?(plan.changes, &(&1.target_app == :credo))
    end
  end

  describe "build/3 — missing repos / mix.exs" do
    test "skips siblings that are missing on disk with a warning",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      # Declare an extra sibling in contrib.exs that doesn't exist on disk
      # AND that depends on req_llm (transitively, after we declare it).
      File.write!(Path.join(tmp_dir, "graft.exs"), """
      %{
        root: ".",
        siblings: [
          %{name: :req_llm, path: "req_llm"},
          %{name: :jido_ai, path: "jido_ai"},
          %{name: :ghost,   path: "ghost"}
        ]
      }
      """)

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # ghost has no mix.exs to read, contributes no deps, no changes.
      assert :ghost not in plan.affected_repos
      assert plan.affected_repos == [:jido_ai]
    end
  end

  describe "build/3 — determinism" do
    test "identical inputs produce identical changes/affected_repos/target_apps",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido, [{:jido_ai, "~> 1.0"}, {:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws, [:req_llm])
      {:ok, p2} = Plan.build(ws, [:req_llm])

      assert p1.target_apps == p2.target_apps
      assert p1.affected_repos == p2.affected_repos

      assert Enum.map(p1.changes, &{&1.repo, &1.target_app}) ==
               Enum.map(p2.changes, &{&1.repo, &1.target_app})

      assert Enum.map(p1.changes, & &1.proposed_mix_exs_after_hash) ==
               Enum.map(p2.changes, & &1.proposed_mix_exs_after_hash)
    end

    test "target order in input doesn't change plan output", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:a, []},
        {:b, []},
        {:c, [{:a, "~> 1.0"}, {:b, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, p_ab} = Plan.build(ws, [:a, :b])
      {:ok, p_ba} = Plan.build(ws, [:b, :a])

      assert p_ab.target_apps == p_ba.target_apps
      assert p_ab.affected_repos == p_ba.affected_repos

      assert Enum.map(p_ab.changes, &{&1.repo, &1.target_app}) ==
               Enum.map(p_ba.changes, &{&1.repo, &1.target_app})
    end
  end

  describe "build/3 — no-op plan" do
    test "target with no consumers returns an empty plan, not an error",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, [{:credo, "~> 1.7"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      assert {:ok, plan} = Plan.build(ws, [:req_llm])

      assert plan.operation == :link_on
      assert plan.target_apps == [:req_llm]
      assert plan.affected_repos == []
      assert plan.changes == []
      assert plan.warnings == []
    end
  end

  describe "build/3 — path rewrite planning" do
    test "computes a sibling-relative path for the replacement",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      [change] = plan.changes
      assert change.dependency_source_after =~ ~s|path: "../req_llm"|
    end
  end

  describe "build/3 — multiple target apps" do
    test "expands closures for every target", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, []},
        {:consumer, [{:foo, "~> 1.0"}, {:bar, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:foo, :bar])

      assert plan.target_apps == [:bar, :foo]
      assert plan.affected_repos == [:consumer]

      pairs = Enum.map(plan.changes, &{&1.repo, &1.target_app}) |> Enum.sort()
      assert pairs == [{:consumer, :bar}, {:consumer, :foo}]
    end

    test "deduplicates target apps", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:foo, :foo, :foo])

      assert plan.target_apps == [:foo]
    end
  end

  describe "build/3 — operation handling" do
    test ":link_off returns :not_implemented", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :not_implemented}} =
               Plan.build(ws, [:foo], operation: :link_off)
    end

    test "unknown operation rejected", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :plan_invalid_operation}} =
               Plan.build(ws, [:foo], operation: :weirdo)
    end

    test "empty target list rejected", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :plan_invalid_operation}} = Plan.build(ws, [])
    end
  end

  ## ─── Fixtures ───────────────────────────────────────────────────────

  # build_workspace(tmp_dir, [
  #   {:req_llm, []},
  #   {:jido_ai, [{:req_llm, "~> 1.0"}]}
  # ])
  defp build_workspace(tmp_dir, sibling_specs) do
    siblings_for_manifest =
      Enum.map_join(sibling_specs, ",\n    ", fn {name, _deps} ->
        ~s|%{name: #{inspect(name)}, path: #{inspect(Atom.to_string(name))}}|
      end)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        #{siblings_for_manifest}
      ]
    }
    """)

    Enum.each(sibling_specs, fn {name, deps} ->
      sibling_dir = Path.join(tmp_dir, Atom.to_string(name))
      File.mkdir_p!(sibling_dir)
      File.write!(Path.join(sibling_dir, "mix.exs"), mix_exs_for(name, deps))
    end)
  end

  defp mix_exs_for(app, deps) do
    rendered =
      Enum.map_join(deps, ",\n      ", fn {dep_app, version} ->
        ~s|{#{inspect(dep_app)}, #{inspect(version)}}|
      end)

    """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          #{rendered}
        ]
      end
    end
    """
  end
end
