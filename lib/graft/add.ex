defmodule Graft.Add do
  @moduledoc """
  Clone repositories into the workspace and optionally register them in
  `graft.exs`.

  Accepts a list of `owner/repo` strings, clones each to a directory named
  after the repo, verifies the clone, and optionally appends the new repo to
  the workspace manifest.
  """

  alias Graft.{Error, GitRemote, Manifest, Safety}

  @type result :: :ok | {:error, Error.t()}

  @doc """
  Clone `owner/repo` repositories into the workspace rooted at `root`.

  Returns a map of `owner/repo => result` for each requested repository.

  Options:
    * `:to_manifest` — append successfully-cloned repos to `graft.exs`
    * `:link` — suggest `mix graft.link.on` for any existing sibling that
      depends on the newly-added repo (not yet implemented)
  """
  @spec clone([String.t()], Path.t(), keyword()) :: %{String.t() => result}
  def clone(owner_repos, root, opts \\ []) do
    owner_repos
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_owner_repo/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {owner_repo, repo_name} ->
      dest = Path.join(root, repo_name)

      result =
        with :ok <- Safety.valid_repo_name?(repo_name),
             :ok <- Safety.within_root?(dest, root),
             :ok <- verify_symlink_target(dest, root),
             :ok <- clone_repo("https://github.com/#{owner_repo}.git", dest),
             :ok <- verify_repo(dest),
             {:ok, manifest} <- maybe_update_manifest(owner_repo, repo_name, root, dest, opts) do
          if manifest do
            :ok
          else
            :ok
          end
        end

      {owner_repo, result}
    end)
    |> Map.new()
  end

  ## ─── Parse ────────────────────────────────────────────────────────

  defp parse_owner_repo(string) do
    case String.split(string, "/", parts: 2, trim: true) do
      [owner, repo] -> {"#{owner}/#{repo}", repo}
      _ -> nil
    end
  end

  ## ─── Clone ────────────────────────────────────────────────────────

  defp clone_repo(url, dest) do
    if File.dir?(dest) do
      verify_existing_remote(dest, url)
    else
      case System.cmd("git", ["clone", "--depth", "1", url, dest], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error,
           Error.new(
             :clone_failed,
             "git clone exited with status #{status}: #{String.trim(output)}",
             %{url: url, dest: dest}
           )}
      end
    end
  end

  defp verify_existing_remote(dest, expected_url) do
    case System.cmd("git", ["-C", dest, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} ->
        actual = String.trim(output)

        if GitRemote.same?(actual, expected_url) do
          :ok
        else
          {:error,
           Error.new(
             :clone_destination_exists,
             "Directory #{dest} already exists with different remote origin (#{actual})",
             %{dest: dest, expected: expected_url, actual: actual}
           )}
        end

      {output, status} ->
        {:error,
         Error.new(
           :clone_destination_exists,
           "Directory #{dest} exists but is not a valid git repository (status #{status}): #{String.trim(output)}",
           %{dest: dest}
         )}
    end
  end

  defp verify_symlink_target(dest, root) do
    case File.lstat(dest) do
      {:ok, %{type: :symlink}} ->
        case Safety.real_path(dest) do
          {:ok, resolved} ->
            Safety.within_root?(resolved, root)

          {:error, reason} ->
            {:error,
             Error.new(
               :runner_fence_violation,
               "Cannot resolve symlink #{dest}: #{inspect(reason)}"
             )}
        end

      _ ->
        :ok
    end
  end

  ## ─── Verify ───────────────────────────────────────────────────────

  defp verify_repo(dest) do
    mix_exs = Path.join(dest, "mix.exs")

    if File.regular?(mix_exs) do
      :ok
    else
      {:error,
       Error.new(
         :repo_not_elixir,
         "Cloned #{dest} but no mix.exs found — is this an Elixir project?",
         %{dest: dest}
       )}
    end
  end

  ## ─── Manifest ─────────────────────────────────────────────────────

  defp maybe_update_manifest(owner_repo, repo_name, root, _dest, opts) do
    if opts[:to_manifest] do
      name = String.to_atom(repo_name)
      origin = "https://github.com/#{owner_repo}.git"
      new_entry = %{name: name, path: repo_name, origin: origin}

      case Manifest.load(root) do
        {:ok, manifest} ->
          if Enum.any?(manifest.siblings, &(&1.name == name)) do
            {:ok, false}
          else
            write_manifest(
              manifest.source_path,
              manifest.root_declared,
              manifest.siblings ++ [new_entry]
            )
          end

        {:error, %{kind: :manifest_not_found}} ->
          path = Path.join(root, Manifest.filename())
          write_manifest(path, ".", [new_entry])

        {:error, err} ->
          {:error, err}
      end
    else
      {:ok, false}
    end
  end

  defp write_manifest(path, root_declared, siblings) do
    case Manifest.write(path, root_declared, siblings) do
      :ok -> {:ok, true}
      {:error, %Error{} = err} -> {:error, err}
    end
  end
end
