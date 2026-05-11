defmodule Graft.Validate.Runner do
  @moduledoc """
  Executes a `Graft.Validate.Plan` sequentially.

  ## Trust contract

    * Every reported pass is real (every command ran and exited 0).
    * `result.passed?` is `true` iff every effective command passed.
    * `first_failure` is the *earliest* topological failure — the
      single place to look first.
    * Skipped ≠ failed. Fail-fast marks every command after the first
      failure as `:skipped`, never as `:failed`.
    * No retries, no parallelism, no caching, no daemons. The runner
      shells out to `mix`, captures output, and tells you what
      happened.

  ## Lock

  Validate intentionally does **not** acquire `.graft/lock`. It only
  mutates `_build/`, `deps/`, and `mix.lock` inside each sibling — none
  of which are part of Graft's workspace trust contract. Running
  `link.on` followed by `validate` from the same shell is the common
  case and must not deadlock.

  ## Streaming

  The caller passes an `:on_event` callback; the runner invokes it for
  every JSONL-shaped event (`run_started`, `command`, `run_result`).
  The Mix task wires this to text or JSONL output. The runner itself
  performs no IO except `System.cmd/3` and the optional log write.

  ## v0.1 limits

    * stdout and stderr are merged (`stderr_to_stdout: true`). Output
      tail is the last ~20 lines of merged output. Live per-line
      streaming during a command is a future capability.
    * Failure categorization is heuristic on `(kind, exit_status,
      output_tail)`. Best-effort, never load-bearing — the full
      transcript is in `.graft/validate.log`.
  """

  alias Graft.Error
  alias Graft.Validate.{Plan, ResultFile}
  alias Graft.Validate.Plan.{Command, Step}

  alias Graft.Validate.Runner.{
    CommandOutcome,
    RepoFailure,
    RepoOutcome,
    Result
  }

  @output_tail_lines 20
  @log_excerpt_lines 40

  @type event :: map()
  @type on_event :: (event() -> any()) | nil
  @type executor ::
          (Command.t(), Path.t() ->
             {:ok, %{exit_status: integer(), output: String.t(), duration_ms: non_neg_integer()}}
             | {:error, :executable_not_found})

  @spec run(Plan.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%Plan{} = plan, opts \\ []) when is_list(opts) do
    fail_fast = Keyword.get(opts, :fail_fast, true)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    executor = Keyword.get(opts, :executor, &default_executor/2)
    log_path = Keyword.get(opts, :log_path, default_log_path(plan))
    persist? = Keyword.get(opts, :persist, true)

    start_time = System.monotonic_time(:millisecond)
    log_io = open_log(log_path)

    emit(on_event, %{
      event: :run_started,
      target_apps: plan.target_apps,
      affected_repos: plan.affected_repos
    })

    {outcomes, _failed?} =
      Enum.reduce(plan.steps, {[], false}, fn step, {acc, failed_so_far?} ->
        if failed_so_far? and fail_fast do
          outcome = skip_step(step)
          emit_repo_events(on_event, outcome)
          {acc ++ [outcome], failed_so_far?}
        else
          outcome = run_step(step, executor, on_event, log_io)
          {acc ++ [outcome], failed_so_far? or outcome.status == :failed}
        end
      end)

    close_log(log_io)

    duration = System.monotonic_time(:millisecond) - start_time
    result = build_result(plan, outcomes, duration, log_path)
    result = maybe_persist(result, plan, persist?)

    emit(on_event, %{event: :run_result, result: result})

    {:ok, result}
  end

  defp maybe_persist(result, _plan, false), do: result

  defp maybe_persist(result, plan, true) do
    case ResultFile.save(plan.workspace_root, plan, result) do
      :ok -> %{result | result_path: ResultFile.path(plan.workspace_root)}
      {:error, %Error{}} -> result
    end
  end

  ## ─── Per-step execution ────────────────────────────────────────────

  defp run_step(%Step{} = step, executor, on_event, log_io) do
    step_start = System.monotonic_time(:millisecond)
    write_log(log_io, "\n=== #{step.repo} (#{step.repo_path}) ===\n")

    {commands, _} =
      Enum.reduce(step.commands, {[], false}, fn cmd, {acc, failed?} ->
        outcome =
          if failed?, do: skip_command(cmd), else: run_command(cmd, step, executor, log_io)

        emit(on_event, command_event(step, outcome))
        {acc ++ [outcome], failed? or outcome.status == :failed}
      end)

    status = rollup(commands)

    %RepoOutcome{
      repo: step.repo,
      repo_path: step.repo_path,
      status: status,
      duration_ms: System.monotonic_time(:millisecond) - step_start,
      commands: commands
    }
  end

  defp skip_step(%Step{} = step) do
    %RepoOutcome{
      repo: step.repo,
      repo_path: step.repo_path,
      status: :skipped,
      duration_ms: 0,
      commands: Enum.map(step.commands, &skip_command/1)
    }
  end

  defp skip_command(%Command{} = c) do
    %CommandOutcome{
      kind: c.kind,
      argv: c.argv,
      description: c.description,
      status: :skipped,
      exit_status: nil,
      duration_ms: 0,
      output_tail: "",
      failure_category: nil
    }
  end

  defp run_command(%Command{} = cmd, %Step{} = step, executor, log_io) do
    write_log(log_io, "\n--- #{step.repo}: #{cmd.description} ---\n")

    case executor.(cmd, step.repo_path) do
      {:ok, %{exit_status: 0, output: output, duration_ms: duration}} ->
        write_log(log_io, output)

        %CommandOutcome{
          kind: cmd.kind,
          argv: cmd.argv,
          description: cmd.description,
          status: :passed,
          exit_status: 0,
          duration_ms: duration,
          output_tail: tail_lines(output, @output_tail_lines),
          failure_category: nil
        }

      {:ok, %{exit_status: status, output: output, duration_ms: duration}} ->
        write_log(log_io, output)

        %CommandOutcome{
          kind: cmd.kind,
          argv: cmd.argv,
          description: cmd.description,
          status: :failed,
          exit_status: status,
          duration_ms: duration,
          output_tail: tail_lines(output, @output_tail_lines),
          failure_category: classify(cmd.kind, status, output)
        }

      {:error, :executable_not_found} ->
        %CommandOutcome{
          kind: cmd.kind,
          argv: cmd.argv,
          description: cmd.description,
          status: :failed,
          exit_status: nil,
          duration_ms: 0,
          output_tail: "mix executable not found in PATH",
          failure_category: :command_not_found
        }
    end
  end

  defp rollup(commands) do
    cond do
      Enum.any?(commands, &(&1.status == :failed)) -> :failed
      Enum.all?(commands, &(&1.status == :passed)) -> :passed
      true -> :skipped
    end
  end

  ## ─── Result assembly ───────────────────────────────────────────────

  defp build_result(plan, outcomes, duration, log_path) do
    passed_count = Enum.count(outcomes, &(&1.status == :passed))
    failed_count = Enum.count(outcomes, &(&1.status == :failed))
    skipped_count = Enum.count(outcomes, &(&1.status == :skipped))

    %Result{
      passed?: failed_count == 0 and Enum.all?(outcomes, &(&1.status != :skipped)),
      first_failure: find_first_failure(outcomes, log_path),
      outcomes: outcomes,
      workspace_root: plan.workspace_root,
      target_apps: plan.target_apps,
      affected_repos: plan.affected_repos,
      passed_count: passed_count,
      failed_count: failed_count,
      skipped_count: skipped_count,
      duration_ms: duration,
      log_path: if(File.exists?(log_path || ""), do: log_path, else: nil)
    }
  end

  defp find_first_failure([], _log_path), do: nil

  defp find_first_failure(outcomes, log_path) do
    Enum.find_value(outcomes, fn %RepoOutcome{} = ro ->
      case Enum.find(ro.commands, &(&1.status == :failed)) do
        nil ->
          nil

        %CommandOutcome{} = co ->
          %RepoFailure{
            repo: ro.repo,
            command_kind: co.kind,
            failure_category: co.failure_category,
            summary: summary_for(ro.repo, co),
            log_excerpt: tail_lines(co.output_tail, @log_excerpt_lines),
            pointer: %{
              repo_path: ro.repo_path,
              command: "mix " <> Enum.join(co.argv, " "),
              log_path: log_path
            }
          }
      end
    end)
  end

  defp summary_for(repo, %CommandOutcome{} = co) do
    cat = co.failure_category || :unknown
    "#{repo} failed on `mix #{Enum.join(co.argv, " ")}` (#{cat})"
  end

  ## ─── Failure classification ────────────────────────────────────────

  defp classify(kind, exit_status, output) do
    cond do
      kind == :deps_get and exit_status != 0 -> :deps_unresolvable
      kind == :compile and exit_status != 0 -> :compile_error
      kind == :test and test_assertion_failure?(output) -> :test_failure
      kind == :test and exit_status != 0 -> :test_failure
      true -> :unknown
    end
  end

  defp test_assertion_failure?(output) do
    String.contains?(output, "test failed") or
      String.contains?(output, "failure(s)") or
      String.contains?(output, "tests, ")
  end

  ## ─── Events ────────────────────────────────────────────────────────

  defp emit(nil, _event), do: :ok
  defp emit(fun, event) when is_function(fun, 1), do: fun.(event)

  defp emit_repo_events(on_event, %RepoOutcome{} = ro) do
    Enum.each(ro.commands, fn co ->
      emit(on_event, command_event(%Step{repo: ro.repo, repo_path: ro.repo_path}, co))
    end)
  end

  defp command_event(%Step{} = step, %CommandOutcome{} = co) do
    %{
      event: :command,
      repo: step.repo,
      kind: co.kind,
      argv: co.argv,
      status: co.status,
      exit_status: co.exit_status,
      duration_ms: co.duration_ms,
      failure_category: co.failure_category,
      output_tail: co.output_tail
    }
  end

  ## ─── Default executor ──────────────────────────────────────────────

  defp default_executor(%Command{argv: argv}, cwd) do
    case System.find_executable("mix") do
      nil ->
        {:error, :executable_not_found}

      mix_path ->
        start = System.monotonic_time(:millisecond)

        {output, exit_status} =
          System.cmd(mix_path, argv, cd: cwd, stderr_to_stdout: true)

        {:ok,
         %{
           exit_status: exit_status,
           output: output,
           duration_ms: System.monotonic_time(:millisecond) - start
         }}
    end
  end

  ## ─── Log helpers ───────────────────────────────────────────────────

  defp default_log_path(%Plan{workspace_root: root}) do
    Path.join([root, ".graft", "validate.log"])
  end

  defp open_log(nil), do: nil

  defp open_log(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.open(path, [:write, :utf8]) do
          {:ok, io} -> io
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp write_log(nil, _data), do: :ok
  defp write_log(io, data), do: IO.write(io, data)

  defp close_log(nil), do: :ok
  defp close_log(io), do: File.close(io)

  defp tail_lines(text, n) do
    text
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end
end
