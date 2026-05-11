defmodule Mix.Tasks.Graft.Workspace.Dossier do
  @shortdoc "Print a JSON workspace dossier for the given path"

  @moduledoc """
  Print a durable workspace status dossier as JSON.

      mix contrib.workspace.dossier
      mix contrib.workspace.dossier --root path/to/workspace

  The dossier is a read-only summary of the workspace state including
  repo paths, git summary, health, attention flags, and detected
  session metadata (tmux, agent).

  Read-only, side-effect free.
  """

  use Mix.Task

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.Dossier
  alias Graft.Workspace.Dossier.Builder

  @switches [root: :string]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:error, output, :stderr} ->
        Mix.shell().error(output)
        exit({:shutdown, 1})
    end
  end

  @doc """
  Pure entry point for testing: parses argv, builds the snapshot + dossier,
  encodes to JSON, and returns `{:ok, json}` or `{:error, message, :stderr}`.
  """
  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stderr}
  def execute(argv) do
    case parse_opts(argv) do
      {:ok, opts} ->
        root = opts[:root] || File.cwd!()

        case Workspace.snapshot(root) do
          {:ok, snapshot} ->
            dossier = Builder.build(snapshot)
            json = Jason.encode!(Dossier.to_map(dossier), pretty: true)
            {:ok, json}

          {:error, %Error{} = err} ->
            {:error, "graft.workspace.dossier: #{err.message}", :stderr}
        end

      {:error, message} ->
        {:error, "graft.workspace.dossier: #{message}", :stderr}
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
end
