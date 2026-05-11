defmodule Mix.Tasks.Graft.ValidateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Graft.Validate, as: Task

  @moduletag :tmp_dir

  describe "execute/1 — argument errors" do
    test "no targets" do
      assert {:fail, msg, :stderr} = Task.execute([])
      assert msg =~ "at least one target app is required"
    end

    test "unknown target (text)", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])

      assert {:fail, msg, :stderr} = Task.execute(["nope", "--root", tmp_dir])
      assert msg =~ "graft.validate:"
      assert msg =~ "nope"
    end

    test "unknown target (jsonl) — error on stdout", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])

      assert {:fail, output, :stdout} = Task.execute(["nope", "--json", "--root", tmp_dir])
      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "validate_target_not_in_workspace"
    end
  end

  describe "execute/1 — dry-run" do
    test "text shows the execution plan in topological order", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--root", tmp_dir])

      assert output =~ "Graft validate (dry-run)"
      assert output =~ "Targets: req_llm"
      assert output =~ "Affected repos: 2"
      assert output =~ "1. req_llm"
      assert output =~ "   - mix deps.get"
      assert output =~ "   - mix compile --warnings-as-errors"
      assert output =~ "   - mix test"
      assert output =~ "2. jido_ai"
    end

    test "jsonl emits plan_started, repo_planned×N, validation_planned×M, plan_completed",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--json", "--root", tmp_dir])

      events =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      types = Enum.map(events, & &1["event"])

      assert hd(types) == "plan_started"
      assert List.last(types) == "plan_completed"
      assert Enum.count(types, &(&1 == "repo_planned")) == 2
      assert Enum.count(types, &(&1 == "validation_planned")) == 6
      refute Enum.any?(types, &(&1 == "command"))
      refute Enum.any?(types, &(&1 == "run_result"))
    end

    test "jsonl plan_completed reports counts", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--json", "--root", tmp_dir])

      [completed] =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["event"] == "plan_completed"))

      assert completed["repos"] == 1
      assert completed["commands"] == 3
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
      rendered = Enum.map_join(deps, ", ", fn {a, v} -> ~s|{#{inspect(a)}, #{inspect(v)}}| end)

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
