defmodule Graft.Validate.ResultFileTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Validate.{Plan, ResultFile, Runner}
  alias Graft.Validate.Plan.Command
  alias Graft.Validate.ResultFile.Persisted

  @moduletag :tmp_dir

  describe "save + load round-trip" do
    test "all-passed result writes a parseable file with fingerprint",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, result} = Runner.run(plan, executor: always_pass(), log_path: nil)

      # Auto-persisted by Runner.run.
      assert result.result_path == ResultFile.path(tmp_dir)
      assert File.regular?(result.result_path)

      assert {:ok, %Persisted{} = persisted} = ResultFile.load(tmp_dir)
      assert persisted.passed? == true
      assert persisted.passed_count == 2
      assert persisted.failed_count == 0
      assert persisted.target_apps == [:req_llm]
      assert persisted.affected_repos == [:req_llm, :jido_ai]
      assert persisted.repo_statuses == %{req_llm: :passed, jido_ai: :passed}
      assert map_size(persisted.fingerprint) == 2
      assert Map.has_key?(persisted.fingerprint, :req_llm)
      assert Map.has_key?(persisted.fingerprint, :jido_ai)
    end

    test "failed result captures first_failure", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :compile -> {:ok, %{exit_status: 1, output: "compile fail", duration_ms: 5}}
          _ -> {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      {:ok, _result} = Runner.run(plan, executor: executor, log_path: nil)
      {:ok, persisted} = ResultFile.load(tmp_dir)

      assert persisted.passed? == false
      refute is_nil(persisted.first_failure)
      assert persisted.first_failure.repo == :req_llm
      assert persisted.first_failure.command_kind == :compile
      assert persisted.first_failure.failure_category == :compile_error
    end

    test "Runner.run with persist: false does not write the file",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      {:ok, result} = Runner.run(plan, executor: always_pass(), log_path: nil, persist: false)

      assert result.result_path == nil
      refute File.exists?(ResultFile.path(tmp_dir))
    end
  end

  describe "load/1 error paths" do
    test "missing file returns :validate_result_missing", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{kind: :validate_result_missing}} = ResultFile.load(tmp_dir)
    end

    test "malformed JSON returns :validate_result_unreadable", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(ResultFile.path(tmp_dir), "{not json")

      assert {:error, %Error{kind: :validate_result_unreadable}} = ResultFile.load(tmp_dir)
    end

    test "unsupported schema version returns :validate_result_unreadable",
         %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))

      File.write!(
        ResultFile.path(tmp_dir),
        Jason.encode!(%{"version" => 999, "passed" => true})
      )

      assert {:error, %Error{kind: :validate_result_unreadable, details: %{got: 999}}} =
               ResultFile.load(tmp_dir)
    end

    test "missing version field returns :validate_result_unreadable",
         %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(ResultFile.path(tmp_dir), Jason.encode!(%{"passed" => true}))

      assert {:error, %Error{kind: :validate_result_unreadable}} = ResultFile.load(tmp_dir)
    end
  end

  describe "stale?/2" do
    test "fresh result against unchanged workspace is not stale", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}, {:jido_ai, [{:req_llm, "~> 1.0"}]}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, _} = Runner.run(plan, executor: always_pass(), log_path: nil)

      {:ok, persisted} = ResultFile.load(tmp_dir)
      refute ResultFile.stale?(ws, persisted)
    end

    test "modifying any consumer mix.exs makes the result stale",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}, {:jido_ai, [{:req_llm, "~> 1.0"}]}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, _} = Runner.run(plan, executor: always_pass(), log_path: nil)

      # Tamper one mix.exs.
      jido_mix = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      File.write!(jido_mix, File.read!(jido_mix) <> "\n# manual edit\n")

      {:ok, persisted} = ResultFile.load(tmp_dir)
      assert ResultFile.stale?(ws, persisted)
    end

    test "removing a fingerprinted repo's mix.exs makes the result stale",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}, {:jido_ai, [{:req_llm, "~> 1.0"}]}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, _} = Runner.run(plan, executor: always_pass(), log_path: nil)

      File.rm!(Path.join([tmp_dir, "jido_ai", "mix.exs"]))

      {:ok, persisted} = ResultFile.load(tmp_dir)
      assert ResultFile.stale?(ws, persisted)
    end
  end

  describe "Workspace.snapshot/1 surface" do
    test "snapshot.validate_result is nil before any run", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      assert ws.validate_result == nil
    end

    test "snapshot.validate_result is populated after a run", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}, {:jido_ai, [{:req_llm, "~> 1.0"}]}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, _} = Runner.run(plan, executor: always_pass(), log_path: nil)

      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      assert %Persisted{passed?: true} = ws2.validate_result
    end

    test "snapshot.validate_result is nil if the file is corrupt", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(ResultFile.path(tmp_dir), "{not json")

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      assert ws.validate_result == nil
    end
  end

  ## ─── helpers ────────────────────────────────────────────────────────

  defp always_pass do
    fn _cmd, _cwd -> {:ok, %{exit_status: 0, output: "", duration_ms: 5}} end
  end

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
