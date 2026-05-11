defmodule Graft.Validate.Plan.Render do
  @moduledoc """
  Renders `Graft.Validate.Plan` for `--dry-run` and renders
  `Graft.Validate.Runner.Result` for completed runs.

  Two output modes:

    * `:text` — human summary plus per-repo command lists.
    * `:jsonl` — newline-delimited JSON events. The dry-run stream is
      `plan_started`, `repo_planned` × N, `validation_planned` × M,
      `plan_completed`. Result stream prepends those, then emits one
      `command` event per finished command, then `run_result`.
  """

  alias Graft.CLI.Errors
  alias Graft.Validate.Plan
  alias Graft.Validate.Plan.{Command, Step}
  alias Graft.Validate.Runner.{CommandOutcome, RepoFailure, RepoOutcome, Result}

  @type format :: :text | :jsonl

  @spec render(Plan.t(), format()) :: String.t()
  def render(plan, format \\ :text)
  def render(%Plan{} = plan, :text), do: render_text(plan)
  def render(%Plan{} = plan, :jsonl), do: render_jsonl_plan(plan)

  @spec render_result(Plan.t(), Result.t(), format()) :: String.t()
  def render_result(plan, result, format \\ :text)
  def render_result(%Plan{} = p, %Result{} = r, :text), do: render_text_result(p, r)
  def render_result(%Plan{} = p, %Result{} = r, :jsonl), do: render_jsonl_result(p, r)

  ## ─── Dry-run plan events (used by both text and JSONL) ─────────────

  @doc """
  Build the ordered list of plan events any consumer can replay
  identically. Returns event maps (not JSON strings).
  """
  @spec plan_events(Plan.t()) :: [map()]
  def plan_events(%Plan{} = plan) do
    started = %{
      event: :plan_started,
      workspace_root: plan.workspace_root,
      target_apps: plan.target_apps,
      affected_repos: plan.affected_repos
    }

    repo_events =
      plan.steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, position} ->
        %{
          event: :repo_planned,
          position: position,
          repo: step.repo,
          repo_path: step.repo_path,
          command_count: length(step.commands)
        }
      end)

    validation_events =
      Enum.flat_map(plan.steps, fn step ->
        Enum.map(step.commands, fn cmd ->
          %{
            event: :validation_planned,
            repo: step.repo,
            kind: cmd.kind,
            argv: cmd.argv,
            description: cmd.description
          }
        end)
      end)

    completed = %{
      event: :plan_completed,
      repos: length(plan.steps),
      commands: Enum.sum(Enum.map(plan.steps, &length(&1.commands))),
      warnings: plan.warnings
    }

    [started] ++ repo_events ++ validation_events ++ [completed]
  end

  ## ─── Text: dry-run ──────────────────────────────────────────────────

  defp render_text(%Plan{} = plan) do
    header = [
      "Graft validate (dry-run)",
      "Workspace: #{plan.workspace_root}",
      "Targets: #{Enum.map_join(plan.target_apps, ", ", &Atom.to_string/1)}",
      "Affected repos: #{length(plan.affected_repos)}",
      ""
    ]

    body =
      plan.steps
      |> Enum.with_index(1)
      |> Enum.flat_map(&render_step_block/1)

    warnings =
      case plan.warnings do
        [] -> []
        ws -> ["", "Warnings:" | Enum.map(ws, &"  ! #{&1}")]
      end

    (header ++ body ++ warnings)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp render_step_block({%Step{} = step, position}) do
    [
      "#{position}. #{step.repo}"
      | Enum.map(step.commands, fn %Command{description: d} -> "   - #{d}" end)
    ] ++ [""]
  end

  ## ─── Text: applied result ──────────────────────────────────────────

  defp render_text_result(%Plan{} = plan, %Result{} = result) do
    if result.passed? do
      total_commands =
        result.outcomes
        |> Enum.flat_map(& &1.commands)
        |> Enum.count(&(&1.status == :passed))

      duration_s = format_duration(result.duration_ms)

      "Validate ✓ in #{duration_s} (#{length(result.outcomes)} repos, #{total_commands} commands)"
    else
      render_failure_summary(plan, result)
    end
  end

  defp render_failure_summary(_plan, %Result{} = result) do
    lines =
      List.flatten([
        failure_block(result.first_failure),
        "",
        skipped_repos_line(result),
        "",
        verdict_line(result)
      ])

    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp failure_block(nil) do
    ["✗ validate could not run"]
  end

  defp failure_block(%RepoFailure{} = f) do
    excerpt =
      f.log_excerpt
      |> String.split("\n", trim: true)
      |> Enum.take(5)
      |> Enum.map(&"  #{&1}")

    [
      "✗ #{f.summary}"
      | excerpt
    ] ++
      [
        "  → log: #{Map.get(f.pointer, :log_path) || "(no log)"}"
      ]
  end

  defp skipped_repos_line(%Result{skipped_count: 0}), do: ""

  defp skipped_repos_line(%Result{} = result) do
    skipped =
      result.outcomes
      |> Enum.filter(&(&1.status == :skipped))
      |> Enum.map(&Atom.to_string(&1.repo))

    "  → #{result.skipped_count} downstream repo(s) skipped: #{Enum.join(skipped, ", ")}"
  end

  defp verdict_line(%Result{} = r) do
    duration_s = format_duration(r.duration_ms)

    "Validate ✗ in #{duration_s} (#{r.passed_count} passed, #{r.failed_count} failed, #{r.skipped_count} skipped)"
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  ## ─── JSONL: dry-run plan stream ────────────────────────────────────

  defp render_jsonl_plan(%Plan{} = plan) do
    plan
    |> plan_events()
    |> Enum.map(&encode_event/1)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  ## ─── JSONL: result stream ─────────────────────────────────────────

  defp render_jsonl_result(%Plan{} = plan, %Result{} = result) do
    plan_lines =
      plan
      |> plan_events()
      |> Enum.map(&encode_event/1)

    command_lines =
      result.outcomes
      |> Enum.flat_map(fn %RepoOutcome{} = ro ->
        Enum.map(ro.commands, &command_event_json(ro, &1))
      end)
      |> Enum.map(&encode_event/1)

    final = encode_event(run_result_event(result))

    (plan_lines ++ command_lines ++ [final])
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp command_event_json(%RepoOutcome{} = ro, %CommandOutcome{} = co) do
    %{
      event: :command,
      repo: ro.repo,
      kind: co.kind,
      argv: co.argv,
      status: co.status,
      exit_status: co.exit_status,
      duration_ms: co.duration_ms,
      failure_category: co.failure_category,
      output_tail: co.output_tail
    }
  end

  defp run_result_event(%Result{} = r) do
    %{
      event: :run_result,
      passed: r.passed?,
      first_failure: first_failure_json(r.first_failure),
      passed_count: r.passed_count,
      failed_count: r.failed_count,
      skipped_count: r.skipped_count,
      affected_repos: r.affected_repos,
      target_apps: r.target_apps,
      workspace_root: r.workspace_root,
      duration_ms: r.duration_ms,
      log_path: r.log_path,
      outcomes: Enum.map(r.outcomes, &outcome_json/1)
    }
  end

  defp first_failure_json(nil), do: nil

  defp first_failure_json(%RepoFailure{} = f) do
    %{
      repo: f.repo,
      command_kind: f.command_kind,
      failure_category: f.failure_category,
      summary: f.summary,
      log_excerpt: f.log_excerpt,
      pointer: f.pointer
    }
  end

  defp outcome_json(%RepoOutcome{} = ro) do
    %{
      repo: ro.repo,
      repo_path: ro.repo_path,
      status: ro.status,
      duration_ms: ro.duration_ms,
      commands: Enum.map(ro.commands, &command_outcome_json/1)
    }
  end

  defp command_outcome_json(%CommandOutcome{} = co) do
    %{
      kind: co.kind,
      argv: co.argv,
      description: co.description,
      status: co.status,
      exit_status: co.exit_status,
      duration_ms: co.duration_ms,
      failure_category: co.failure_category,
      output_tail: co.output_tail
    }
  end

  defp encode_event(event) do
    event
    |> Errors.jsonable()
    |> Jason.encode!()
  end
end
