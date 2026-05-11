defmodule Mix.Tasks.Graft.Validate do
  @shortdoc "Validate that a target and its consumers build and test cleanly"

  @moduledoc """
  Run `mix deps.get → mix compile --warnings-as-errors → mix test` across
  the target's transitive consumer closure, in topological dependency
  order. Answers a single question:

      did my cross-repo change actually work?

  ## Usage

      mix graft.validate req_llm                # run; text output; fail-fast
      mix graft.validate req_llm --dry-run      # show the plan only
      mix graft.validate req_llm --json         # JSONL output for agents
      mix graft.validate req_llm --continue     # run every repo even after a failure

  ## Trust contract

    * `passed?: true` means every command in every affected repo ran
      and exited 0. Skipped commands never count as passed.
    * `first_failure` is the earliest topological failure. One place
      to look first.
    * Skipped ≠ failed. Fail-fast aborts downstream repos; they are
      reported as skipped, not failed.
    * Exit code is 0 iff `passed? == true`.

  No git, no `deps.unlock`, no parallelism, no retry, no daemon.
  """

  use Mix.Task

  alias Graft.{Error, Workspace}
  alias Graft.CLI.Errors
  alias Graft.Validate.{Plan, Runner}
  alias Graft.Validate.Plan.Render

  @switches [json: :boolean, dry_run: :boolean, root: :string, continue: :boolean]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:fail, output, :stdout} ->
        Mix.shell().info(output)
        exit({:shutdown, 1})

      {:fail, output, :stderr} ->
        Mix.shell().error(output)
        exit({:shutdown, 1})
    end
  end

  @doc false
  def execute(argv) do
    case parse_args(argv) do
      {:ok, opts, target_strings} ->
        format = if opts[:json], do: :jsonl, else: :text

        cond do
          target_strings == [] ->
            {:fail, "graft.validate: at least one target app is required", :stderr}

          true ->
            do_execute(opts, target_strings, format)
        end

      {:error, msg} ->
        {:fail, "graft.validate: #{msg}", :stderr}
    end
  end

  defp parse_args(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    {:ok, opts, positional}
  rescue
    e in OptionParser.ParseError -> {:error, Exception.message(e)}
  end

  defp do_execute(opts, target_strings, format) do
    root = opts[:root] || File.cwd!()
    dry_run? = Keyword.get(opts, :dry_run, false)
    fail_fast? = not Keyword.get(opts, :continue, false)

    with {:ok, snapshot} <- Workspace.snapshot(root),
         {:ok, targets} <- resolve_targets(target_strings, snapshot),
         {:ok, plan} <- Plan.build(snapshot, targets) do
      cond do
        dry_run? ->
          {:ok, Render.render(plan, format)}

        true ->
          {:ok, result} = Runner.run(plan, fail_fast: fail_fast?)

          output = Render.render_result(plan, result, format)

          if result.passed? do
            {:ok, output}
          else
            stream = if format == :jsonl, do: :stdout, else: :stderr
            {:fail, output, stream}
          end
      end
    else
      {:error, %Error{} = err} -> format_error(err, format)
    end
  end

  defp resolve_targets(strings, snapshot) do
    by_name = Map.new(snapshot.repos, fn r -> {Atom.to_string(r.name), r.name} end)

    Enum.reduce_while(strings, {:ok, []}, fn s, {:ok, acc} ->
      case Map.fetch(by_name, s) do
        {:ok, atom} ->
          {:cont, {:ok, [atom | acc]}}

        :error ->
          {:halt,
           {:error,
            Error.new(
              :validate_target_not_in_workspace,
              "Target app(s) not declared as siblings in graft.exs: [#{s}]",
              %{targets: [s]}
            )}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp format_error(%Error{} = err, :jsonl) do
    case Errors.format(err, :json, "graft.validate") do
      {:error, output, _stream} -> {:fail, output, :stdout}
    end
  end

  defp format_error(%Error{} = err, :text) do
    case Errors.format(err, :text, "graft.validate") do
      {:error, output, stream} -> {:fail, output, stream}
    end
  end
end
