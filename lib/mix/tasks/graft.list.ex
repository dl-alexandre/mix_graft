defmodule Mix.Tasks.Graft.List do
  @shortdoc "List declared workspace siblings"

  @moduledoc """
  Render the workspace manifest as a concise, read-only listing.

      mix graft.list
      mix graft.list --json
      mix graft.list --root path/to/workspace

  Unlike `mix graft.status`, this does **not** snapshot the workspace,
  parse `mix.exs`, call `git`, or check Hex. It only reads `graft.exs`
  and checks whether each declared sibling path exists on disk.

  Exits 0 on success, non-zero on error. In `--json` mode, errors are
  written to stdout as a structured JSON object.
  """

  use Mix.Task

  alias Graft.{Error, List}
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
  Pure entry point for testing: parses argv, loads the manifest, renders,
  and returns either `{:ok, output}` or `{:error, output, stream}`.
  """
  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stdout | :stderr}
  def execute(argv) do
    case parse_opts(argv) do
      {:ok, opts} ->
        format = if opts[:json], do: :json, else: :text
        root = opts[:root] || File.cwd!()

        case List.render(root, format) do
          {:ok, output} -> {:ok, output}
          {:error, %Error{} = err} -> format_error(err, format)
        end

      {:error, message} ->
        {:error, "graft.list: #{message}", :stderr}
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

  defp format_error(%Error{} = err, format), do: Errors.format(err, format, "graft.list")
end
