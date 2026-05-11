defmodule Graft.Validate.RunnerTest do
  use ExUnit.Case, async: true

  alias Graft.Workspace
  alias Graft.Validate.{Plan, Runner}
  alias Graft.Validate.Plan.Command
  alias Graft.Validate.Runner.{RepoFailure, Result}

  @moduletag :tmp_dir

  describe "happy path" do
    test "every command passes; passed? is true; first_failure is nil",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:ok, %Result{} = result} = Runner.run(plan, executor: always_pass())

      assert result.passed? == true
      assert result.first_failure == nil
      assert result.failed_count == 0
      assert result.skipped_count == 0
      assert result.passed_count == 2
      assert Enum.map(result.outcomes, & &1.status) == [:passed, :passed]

      assert Enum.map(result.outcomes, & &1.repo) == [:req_llm, :jido_ai]
    end
  end

  describe "fail-fast default" do
    test "first failure halts; downstream repos are skipped, not failed",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:jido_ai, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # Fail :req_llm's compile.
      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :compile ->
            {:ok,
             %{
               exit_status: 1,
               output: "** (Mix) compilation failed\nwarning: oops",
               duration_ms: 50
             }}

          _ ->
            {:ok, %{exit_status: 0, output: "", duration_ms: 10}}
        end
      end

      {:ok, result} = Runner.run(plan, executor: executor)

      assert result.passed? == false
      assert result.failed_count == 1
      assert result.skipped_count == 2

      [r1, r2, r3] = result.outcomes
      assert r1.repo == :req_llm
      assert r1.status == :failed
      assert Enum.map(r1.commands, & &1.status) == [:passed, :failed, :skipped]

      assert r2.repo == :jido_ai
      assert r2.status == :skipped
      assert Enum.all?(r2.commands, &(&1.status == :skipped))

      assert r3.repo == :jido_chat
      assert r3.status == :skipped
    end

    test "first_failure points at the earliest topological failure, not the worst",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :compile ->
            {:ok, %{exit_status: 1, output: "compile fail", duration_ms: 10}}

          _ ->
            {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      {:ok, result} = Runner.run(plan, executor: executor)

      assert %RepoFailure{
               repo: :req_llm,
               command_kind: :compile,
               failure_category: :compile_error
             } =
               result.first_failure
    end
  end

  describe "--continue mode" do
    test "every repo runs even after a failure; passed? still false",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # :req_llm fails at compile, :jido_ai passes everything.
      executor = fn %Command{kind: kind}, cwd ->
        if String.ends_with?(cwd, "req_llm") and kind == :compile do
          {:ok, %{exit_status: 1, output: "compile fail", duration_ms: 10}}
        else
          {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      {:ok, result} = Runner.run(plan, executor: executor, fail_fast: false)

      assert result.passed? == false
      assert result.failed_count == 1
      assert result.skipped_count == 0
      assert result.passed_count == 1

      assert Enum.map(result.outcomes, &{&1.repo, &1.status}) ==
               [{:req_llm, :failed}, {:jido_ai, :passed}]

      # first_failure is still the earliest topological one.
      assert result.first_failure.repo == :req_llm
    end
  end

  describe "failure categorization" do
    test "deps.get failure → :deps_unresolvable", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: :deps_get}, _cwd ->
        {:ok, %{exit_status: 1, output: "** (Mix) Could not fetch", duration_ms: 10}}
      end

      {:ok, result} = Runner.run(plan, executor: executor)
      assert result.first_failure.failure_category == :deps_unresolvable
    end

    test "compile failure → :compile_error", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :compile -> {:ok, %{exit_status: 1, output: "compile fail", duration_ms: 5}}
          _ -> {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      {:ok, result} = Runner.run(plan, executor: executor)
      assert result.first_failure.failure_category == :compile_error
    end

    test "test failure → :test_failure", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :test -> {:ok, %{exit_status: 2, output: "3 tests, 1 failure", duration_ms: 5}}
          _ -> {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      {:ok, result} = Runner.run(plan, executor: executor)
      assert result.first_failure.failure_category == :test_failure
    end

    test "executable not found → :command_not_found", %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn _, _ -> {:error, :executable_not_found} end

      {:ok, result} = Runner.run(plan, executor: executor)
      assert result.passed? == false
      assert result.first_failure.failure_category == :command_not_found
    end
  end

  describe "streaming events" do
    test "emits run_started, command (one per executed), and run_result",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      parent = self()
      on_event = fn ev -> send(parent, {:event, ev}) end

      {:ok, _} = Runner.run(plan, executor: always_pass(), on_event: on_event)

      events = collect_events([])
      types = Enum.map(events, & &1.event)

      assert hd(types) == :run_started
      assert List.last(types) == :run_result
      assert Enum.count(types, &(&1 == :command)) == 6
    end

    test "fail-fast: skipped commands are still emitted with status :skipped",
         %{tmp_dir: tmp_dir} do
      build_ws(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      executor = fn %Command{kind: kind}, _cwd ->
        case kind do
          :compile -> {:ok, %{exit_status: 1, output: "fail", duration_ms: 5}}
          _ -> {:ok, %{exit_status: 0, output: "", duration_ms: 5}}
        end
      end

      parent = self()

      {:ok, _} =
        Runner.run(plan, executor: executor, on_event: fn e -> send(parent, {:event, e}) end)

      events = collect_events([])
      cmd_events = Enum.filter(events, &(&1.event == :command))

      assert length(cmd_events) == 6

      skipped = Enum.count(cmd_events, &(&1.status == :skipped))
      failed = Enum.count(cmd_events, &(&1.status == :failed))
      assert skipped == 4
      assert failed == 1
    end
  end

  ## ─── helpers ────────────────────────────────────────────────────────

  defp collect_events(acc) do
    receive do
      {:event, ev} -> collect_events(acc ++ [ev])
    after
      0 -> acc
    end
  end

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
