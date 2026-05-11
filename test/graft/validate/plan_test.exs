defmodule Graft.Validate.PlanTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Validate.Plan
  alias Graft.Validate.Plan.Step

  @moduletag :tmp_dir

  describe "build/2" do
    test "single target with no consumers — closure is just the target",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:ok, plan} = Plan.build(ws, [:req_llm])
      assert plan.operation == :validate
      assert plan.target_apps == [:req_llm]
      assert plan.affected_repos == [:req_llm]
      assert [%Step{repo: :req_llm}] = plan.steps

      assert Enum.map(plan.steps |> hd() |> Map.fetch!(:commands), & &1.kind) ==
               [:deps_get, :compile, :test]
    end

    test "target with consumers — closure includes consumers, dependencies validated first",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:jido_ai, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # Topological order: req_llm before jido_ai before jido_chat.
      assert Enum.map(plan.steps, & &1.repo) == [:req_llm, :jido_ai, :jido_chat]
      assert plan.affected_repos == [:req_llm, :jido_ai, :jido_chat]
    end

    test "topological ordering breaks ties alphabetically within a layer",
         %{tmp_dir: tmp_dir} do
      # Two consumers at the same depth: alphabetic sub-order.
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:zeta_consumer, [{:req_llm, "~> 1.0"}]},
        {:alpha_consumer, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert Enum.map(plan.steps, & &1.repo) == [:req_llm, :alpha_consumer, :zeta_consumer]
    end

    test "cycle is warned about, not refused", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:a, [{:b, "~> 1.0"}]},
        {:b, [{:a, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:a])

      assert Enum.map(plan.steps, & &1.repo) |> Enum.sort() == [:a, :b]
      assert [_] = plan.warnings
      assert hd(plan.warnings) =~ "Cycle"
    end

    test "rejects unknown target", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :validate_target_not_in_workspace}} =
               Plan.build(ws, [:not_a_sibling])
    end

    test "rejects empty target list", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :plan_invalid_operation}} = Plan.build(ws, [])
    end

    test "deterministic across re-runs with same input", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws, [:req_llm])
      {:ok, p2} = Plan.build(ws, [:req_llm])

      assert Enum.map(p1.steps, & &1.repo) == Enum.map(p2.steps, & &1.repo)
      assert p1.affected_repos == p2.affected_repos
    end
  end

  ## ─── fixture ────────────────────────────────────────────────────────

  defp build_ws(tmp_dir, sibling_specs) do
    siblings =
      Enum.map_join(sibling_specs, ",\n    ", fn {name, _} ->
        ~s|%{name: #{inspect(name)}, path: #{inspect(Atom.to_string(name))}}|
      end)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{root: ".", siblings: [
      #{siblings}
    ]}
    """)

    Enum.each(sibling_specs, fn {name, deps} ->
      dir = Path.join(tmp_dir, Atom.to_string(name))
      File.mkdir_p!(dir)

      rendered =
        Enum.map_join(deps, ", ", fn {a, v} -> ~s|{#{inspect(a)}, #{inspect(v)}}| end)

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule #{Macro.camelize(Atom.to_string(name))}.MixProject do
        use Mix.Project
        def project, do: [app: #{inspect(name)}, version: "0.1.0", deps: deps()]
        defp deps, do: [#{rendered}]
      end
      """)
    end)
  end
end
