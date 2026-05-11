defmodule Mix.Tasks.Graft.Add do
  @shortdoc "Clone repositories into the workspace"

  @moduledoc """
  Clone `owner/repo` repositories from GitHub into the workspace.

      mix graft.add owner1/repo1 owner2/repo2
      mix graft.add owner/repo --to-manifest
      mix graft.add owner/repo --root path/to/workspace

  Each repo is cloned to a directory named after the repository.
  If the directory already exists and has the correct remote origin,
  the clone is skipped (idempotent).

  ## Flags

    * `--to-manifest` — append the new repo to `graft.exs` as a sibling
    * `--root PATH`   — operate in a different workspace root
  """

  use Mix.Task

  alias Graft.Add

  @switches [to_manifest: :boolean, root: :string]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end

  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def execute(argv) do
    case OptionParser.parse!(argv, strict: @switches) do
      {opts, owner_repos} when owner_repos != [] ->
        root = opts[:root] || File.cwd!()
        results = Add.clone(owner_repos, root, to_manifest: opts[:to_manifest] || false)
        {:ok, format_results(results)}

      {_opts, []} ->
        {:error, usage()}
    end
  rescue
    e in OptionParser.ParseError ->
      {:error, "graft.add: #{Exception.message(e)}\n\n#{usage()}"}
  end

  ## ─── Formatting ─────────────────────────────────────────────────────

  defp format_results(results) do
    lines =
      Enum.map(results, fn {repo, result} ->
        case result do
          :ok -> "  #{check()} #{repo}"
          {:error, err} -> "  #{cross()} #{repo}: #{err.message}"
        end
      end)

    successes = Enum.count(results, fn {_, r} -> r == :ok end)
    failures = map_size(results) - successes

    header =
      case {successes, failures} do
        {s, 0} -> "Added #{s} repository(s):"
        {0, f} -> "Failed to add #{f} repository(s):"
        {s, f} -> "Added #{s}, failed #{f}:"
      end

    [header | lines]
    |> Enum.join("\n")
  end

  defp check, do: if(no_color?(), do: "[OK]", else: "✓")
  defp cross, do: if(no_color?(), do: "[ERR]", else: "✗")

  defp no_color? do
    System.get_env("NO_COLOR") in ["1", "true"] or System.get_env("TERM") == "dumb"
  end

  defp usage do
    """
    Usage: mix graft.add OWNER/REPO [OWNER/REPO ...] [options]

    Options:
      --to-manifest    Append cloned repos to graft.exs
      --root PATH      Workspace root (defaults to current directory)
    """
  end
end
