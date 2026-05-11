defmodule Mix.Tasks.Graft.Link.On do
  @shortdoc "Link sibling repos to local paths for joint development"

  @moduledoc """
  Plan and (eventually) execute path-link rewrites across the workspace.

      mix graft.link.on req_llm --dry-run
      mix graft.link.on req_llm jido --dry-run --json
      mix graft.link.on req_llm --dry-run --root path/to/workspace

  ## Behavior

  With `--dry-run`, the task computes the full mutation plan via
  `Graft.Link.Plan` and renders it without touching the filesystem.

  Without `--dry-run`, the same plan is applied transactionally through
  `Graft.Link.Runner`: every consumer `mix.exs` is rewritten under
  hash verification with atomic writes and LIFO rollback on failure,
  and `.graft/state.json` is persisted on success. No git, no
  `mix deps.unlock`, no `mix deps.get`.

  Exit codes: 0 on success, non-zero on error. In `--json` mode, errors
  are emitted as structured JSON on stdout; otherwise a concise human
  message is written to stderr.
  """

  use Mix.Task

  alias Graft.{Error, Workspace}
  alias Graft.CLI.Errors
  alias Graft.Link.{Plan, Runner}
  alias Graft.Link.Plan.Render

  @switches [json: :boolean, dry_run: :boolean, root: :string]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:error, output, :stdout} ->
        Mix.shell().info(output)
        exit({:shutdown, 1})

      {:error, output, :stderr} ->
        Mix.shell().error(output)
        exit({:shutdown, 1})
    end
  end

  @doc """
  Pure entry point for testing. Returns `{:ok, output}` on success or
  `{:error, output, stream}` where `stream` is `:stdout` or `:stderr`.
  Never writes output and never exits.
  """
  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stdout | :stderr}
  def execute(argv) do
    case parse_args(argv) do
      {:ok, opts, target_strings} ->
        format = if opts[:json], do: :json, else: :text

        cond do
          target_strings == [] ->
            {:error, "graft.link.on: at least one target app is required", :stderr}

          Keyword.get(opts, :dry_run, false) ->
            run_dry_run(opts, target_strings, format)

          true ->
            run_apply(opts, target_strings, format)
        end

      {:error, msg} ->
        {:error, "graft.link.on: #{msg}", :stderr}
    end
  end

  ## ─── Argument parsing ───────────────────────────────────────────────

  # Returns `{opts, target_strings}` — strings are only resolved to
  # atoms after the workspace snapshot is loaded, so only declared
  # sibling names ever become atoms (no atom-exhaustion via untrusted
  # input).
  defp parse_args(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    {:ok, opts, positional}
  rescue
    e in OptionParser.ParseError ->
      {:error, Exception.message(e)}
  end

  ## ─── Dry-run path ───────────────────────────────────────────────────

  defp run_dry_run(opts, target_strings, format) do
    case build_plan(opts, target_strings) do
      {:ok, plan} -> {:ok, Render.render(plan, format)}
      {:error, %Error{} = err} -> format_error(err, format)
    end
  end

  ## ─── Apply path ─────────────────────────────────────────────────────

  defp run_apply(opts, target_strings, format) do
    with {:ok, plan} <- build_plan(opts, target_strings),
         {:ok, result} <- Runner.run(plan) do
      {:ok, Render.render_applied(plan, result, format)}
    else
      {:error, %Error{} = err} -> format_error(err, format)
    end
  end

  defp build_plan(opts, target_strings) do
    root = opts[:root] || File.cwd!()

    with {:ok, snapshot} <- Workspace.snapshot(root),
         {:ok, targets} <- resolve_targets(target_strings, snapshot),
         {:ok, plan} <- Plan.build(snapshot, targets) do
      {:ok, plan}
    end
  end

  # Resolve user-supplied target strings against declared sibling
  # names. We never call `String.to_atom/1`; we look up each string in
  # a name-keyed map of existing sibling atoms.
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
              :plan_target_not_in_workspace,
              "Target app(s) not declared as siblings in graft.exs: [#{s}]",
              %{targets: [s]}
            )}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  ## ─── Error formatting ───────────────────────────────────────────────

  defp format_error(%Error{} = err, format), do: Errors.format(err, format, "graft.link.on")
end
