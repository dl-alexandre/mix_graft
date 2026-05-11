defmodule Graft.GoldenTest do
  use ExUnit.Case, async: true

  alias Graft.{State, Status, Workspace}
  alias Graft.CLI.Errors
  alias Graft.Error
  alias Graft.Link.{Plan, Runner}
  alias Graft.Link.Plan.Render, as: OnRender
  alias Graft.Link.Off
  alias Graft.Link.Off.Plan.Render, as: OffRender
  alias Graft.Validate
  alias Graft.Validate.Plan.Render, as: ValidateRender

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    build_fixture(tmp_dir)
    :ok
  end

  test "status JSON matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    Graft.GoldenJSON.assert_match(Status.render(ws, :json), "status", root: tmp_dir)
  end

  test "link.on dry-run JSON matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Plan.build(ws, [:req_llm])

    Graft.GoldenJSON.assert_match(OnRender.render(plan, :json), "link_on_dry_run", root: tmp_dir)
  end

  test "link.on result JSON matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Plan.build(ws, [:req_llm])
    {:ok, result} = Runner.run(plan)

    Graft.GoldenJSON.assert_match(
      OnRender.render_applied(plan, result, :json),
      "link_on_result",
      root: tmp_dir
    )
  end

  test "link.off dry-run JSON matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan_on} = Plan.build(ws, [:req_llm])
    {:ok, _} = Runner.run(plan_on)

    {:ok, state} = State.load(tmp_dir)
    {:ok, off_plan} = Off.Plan.build(ws, state, [:req_llm])

    Graft.GoldenJSON.assert_match(
      OffRender.render(off_plan, :json),
      "link_off_dry_run",
      root: tmp_dir
    )
  end

  test "link.off result JSON matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan_on} = Plan.build(ws, [:req_llm])
    {:ok, _} = Runner.run(plan_on)

    {:ok, state} = State.load(tmp_dir)
    {:ok, off_plan} = Off.Plan.build(ws, state, [:req_llm])
    {:ok, off_result} = Off.Runner.run(off_plan)

    Graft.GoldenJSON.assert_match(
      OffRender.render_applied(off_plan, off_result, :json),
      "link_off_result",
      root: tmp_dir
    )
  end

  test "validate dry-run JSONL matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Validate.Plan.build(ws, [:req_llm])

    Graft.GoldenJSON.assert_match_jsonl(
      ValidateRender.render(plan, :jsonl),
      "validate_dry_run",
      root: tmp_dir
    )
  end

  test "validate result JSONL (all-pass simulated) matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Validate.Plan.build(ws, [:req_llm])

    executor = fn _cmd, _cwd -> {:ok, %{exit_status: 0, output: "", duration_ms: 0}} end
    {:ok, result} = Validate.Runner.run(plan, executor: executor, log_path: nil, persist: false)

    Graft.GoldenJSON.assert_match_jsonl(
      ValidateRender.render_result(plan, result, :jsonl),
      "validate_result",
      root: tmp_dir
    )
  end

  test "validate persisted result.json matches golden", %{tmp_dir: tmp_dir} do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Validate.Plan.build(ws, [:req_llm])

    executor = fn _cmd, _cwd -> {:ok, %{exit_status: 0, output: "", duration_ms: 0}} end
    {:ok, _result} = Validate.Runner.run(plan, executor: executor, log_path: nil)

    persisted_json = File.read!(Graft.Validate.ResultFile.path(tmp_dir))

    Graft.GoldenJSON.assert_match(persisted_json, "validate_result_file", root: tmp_dir)
  end

  test "error JSON matches golden", %{tmp_dir: tmp_dir} do
    err =
      Error.new(
        :plan_target_not_in_workspace,
        "Target app(s) not declared as siblings in graft.exs: [:nope]",
        %{targets: [:nope]}
      )

    {:error, output, :stdout} = Errors.format(err, :json, "graft.link.on")
    Graft.GoldenJSON.assert_match(output, "error", root: tmp_dir)
  end

  ## ─── Fixture ────────────────────────────────────────────────────────

  defp build_fixture(tmp_dir) do
    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        %{name: :req_llm, path: "req_llm"},
        %{name: :jido_ai, path: "jido_ai"}
      ]
    }
    """)

    File.mkdir_p!(Path.join(tmp_dir, "req_llm"))

    File.write!(Path.join([tmp_dir, "req_llm", "mix.exs"]), """
    defmodule ReqLlm.MixProject do
      use Mix.Project
      def project, do: [app: :req_llm, version: "0.1.0", deps: deps()]
      defp deps, do: []
    end
    """)

    File.mkdir_p!(Path.join(tmp_dir, "jido_ai"))

    File.write!(Path.join([tmp_dir, "jido_ai", "mix.exs"]), """
    defmodule JidoAi.MixProject do
      use Mix.Project
      def project, do: [app: :jido_ai, version: "0.1.0", deps: deps()]
      defp deps, do: [{:req_llm, "~> 1.0"}]
    end
    """)
  end
end
