defmodule Mix.Tasks.Graft.Remove do
  @shortdoc "Remove siblings from the graft manifest"

  @moduledoc """
  Remove sibling entries from `graft.exs`.

      mix graft.remove req_llm --dry-run
      mix graft.remove req_llm
      mix graft.remove req_llm --delete
      mix graft.remove req_llm --delete --force
      mix graft.remove req_llm --json

  By default this only edits `graft.exs`. The sibling directory is deleted only
  when `--delete` is supplied. Dirty git repositories are refused for deletion
  unless `--force` is also supplied.
  """

  use Mix.Task

  alias Graft.{Error, Remove}
  alias Graft.CLI.Errors

  @switches [
    root: :string,
    dry_run: :boolean,
    delete: :boolean,
    force: :boolean,
    json: :boolean
  ]

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

  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stdout | :stderr}
  def execute(argv) do
    case parse_opts(argv) do
      {:ok, opts, targets} ->
        root = opts[:root] || File.cwd!()
        format = if opts[:json], do: :json, else: :text

        case Remove.remove(targets, root,
               dry_run: Keyword.get(opts, :dry_run, false),
               delete: Keyword.get(opts, :delete, false),
               force: Keyword.get(opts, :force, false)
             ) do
          {:ok, result} ->
            {:ok, Remove.render(result, format)}

          {:error, %Remove.Result{} = result} ->
            stream = if format == :json, do: :stdout, else: :stderr
            {:error, Remove.render(result, format), stream}

          {:error, %Error{} = err} ->
            Errors.format(err, format, "graft.remove")
        end

      {:error, message} ->
        {:error, "graft.remove: #{message}", :stderr}
    end
  end

  defp parse_opts(argv) do
    case OptionParser.parse!(argv, strict: @switches) do
      {_opts, []} ->
        {:error, "at least one sibling name is required"}

      {opts, targets} ->
        {:ok, opts, targets}
    end
  rescue
    e in OptionParser.ParseError ->
      {:error, Exception.message(e)}
  end
end
