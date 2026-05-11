defmodule Mix.Tasks.Graft.Status do
  @shortdoc "Show workspace state across sibling repos"

  @moduledoc """
  Renders a snapshot of the Graft workspace.

      mix graft.status
      mix graft.status --json
      mix graft.status --root path/to/workspace

  Read-only, side-effect free. No git, Hex, or GitHub calls.

  Exits 0 on success, non-zero on error. In `--json` mode, errors are
  written to stdout as a structured JSON object; otherwise a concise
  human message is written to stderr.
  """

  use Mix.Task

  alias Graft.{Error, Status, Workspace}
  alias Graft.CLI.Errors

  @switches [json: :boolean, root: :string]

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
  Pure entry point for testing: parses argv, builds the snapshot, renders,
  and returns either `{:ok, output}` or `{:error, output, stream}` where
  `stream` is `:stdout` or `:stderr`.

  Never writes output or exits — the Mix task wrapper handles that.
  """
  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stdout | :stderr}
  def execute(argv) do
    case parse_opts(argv) do
      {:ok, opts} ->
        format = if opts[:json], do: :json, else: :text
        root = opts[:root] || File.cwd!()

        case Workspace.snapshot(root) do
          {:ok, snapshot} -> {:ok, Status.render(snapshot, format)}
          {:error, %Error{} = err} -> format_error(err, format)
        end

      {:error, message} ->
        # Argument-parse errors are always human-form on stderr — we
        # cannot reliably know whether `--json` was intended.
        {:error, "graft.status: #{message}", :stderr}
    end
  end

  ## ─── Argument parsing ───────────────────────────────────────────────

  defp parse_opts(argv) do
    case OptionParser.parse!(argv, strict: @switches) do
      {opts, []} ->
        {:ok, opts}

      {_opts, extra} ->
        {:error, "unexpected arguments: #{Enum.join(extra, " ")}"}
    end
  rescue
    e in OptionParser.ParseError ->
      {:error, Exception.message(e)}
  end

  ## ─── Error formatting ───────────────────────────────────────────────

  defp format_error(%Error{} = err, format), do: Errors.format(err, format, "graft.status")
end
