defmodule Graft.GitState do
  @moduledoc """
  Read-only inspector for a single repo's git posture.

  ## Contract

    * **Observational only.** Every operation shells out to read-only
      `git` subcommands or stats marker files inside `.git/`. No
      command mutates repo state.
    * **No caching, no ambient state.** Every `read/1` is a fresh
      observation. Two consecutive `read/1` calls may legitimately
      return different results if the repo changed on disk between
      them — that is the contract, not a bug.
    * **No background refresh.** This module never spawns a process,
      never registers a Supervisor child, never watches the
      filesystem.
    * **Stable JSON shape.** The struct serializes to a frozen JSON
      contract pinned by golden tests. Adding fields is allowed;
      renaming or removing them is a public-contract break.

  ## Signals

  Per repo, `read/1` returns:

    * `:is_git_repo?` — does `.git/` exist as a directory or file
      (worktree indirection)? If false, every other field is at its
      zero value.
    * `:branch` — current branch name, or `nil` when HEAD is detached.
    * `:detached_head?` — true iff HEAD is detached.
    * `:head_sha` — short SHA of HEAD, or `nil` for an empty repo.
    * `:upstream` — symbolic upstream like `"origin/main"`, or `nil`
      if no upstream is set.
    * `:origin_url` — configured `origin` remote URL, or `nil` when absent.
    * `:ahead` / `:behind` — commit counts relative to the upstream
      (both zero when no upstream is set).
    * `:dirty?` — true iff `git status --porcelain` emits any line.
    * `:in_progress` — `:none | :merge | :rebase | :cherry_pick |
      :bisect | :revert`, detected via marker files inside the git
      directory. Best-effort.
    * `:error` — `nil` on a clean read, or an atom describing a
      structural problem (`:git_not_installed`,
      `:not_a_repo`).

  Repos that aren't git repos at all (or where `git` itself is missing)
  return a struct with `is_git_repo?: false` and the relevant `:error`
  set. The snapshot keeps going.
  """

  @type in_progress ::
          :none | :merge | :rebase | :cherry_pick | :bisect | :revert

  @type error :: nil | :git_not_installed | :not_a_repo

  @type t :: %__MODULE__{
          repo: atom() | nil,
          repo_path: Path.t() | nil,
          is_git_repo?: boolean(),
          branch: String.t() | nil,
          detached_head?: boolean(),
          head_sha: String.t() | nil,
          origin_url: String.t() | nil,
          upstream: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          dirty?: boolean(),
          in_progress: in_progress(),
          error: error()
        }

  defstruct repo: nil,
            repo_path: nil,
            is_git_repo?: false,
            branch: nil,
            detached_head?: false,
            head_sha: nil,
            origin_url: nil,
            upstream: nil,
            ahead: 0,
            behind: 0,
            dirty?: false,
            in_progress: :none,
            error: nil

  @doc """
  Read git posture for the repo rooted at `repo_path`. Returns a
  `%Graft.GitState{}` regardless of outcome; check `:error` and
  `:is_git_repo?` to discriminate failure modes.
  """
  @spec read(Path.t(), keyword()) :: t()
  def read(repo_path, opts \\ []) when is_binary(repo_path) do
    repo_name = Keyword.get(opts, :repo)
    base = %__MODULE__{repo: repo_name, repo_path: repo_path}

    cond do
      System.find_executable("git") == nil ->
        %{base | error: :git_not_installed}

      not File.exists?(Path.join(repo_path, ".git")) ->
        %{base | error: :not_a_repo}

      true ->
        gather(base, repo_path)
    end
  end

  ## ─── Gathering ──────────────────────────────────────────────────────

  defp gather(base, repo_path) do
    base = %{base | is_git_repo?: true}

    base
    |> set_branch(repo_path)
    |> set_head_sha(repo_path)
    |> set_origin_url(repo_path)
    |> set_upstream_and_counts(repo_path)
    |> set_dirty(repo_path)
    |> set_in_progress(repo_path)
  end

  defp set_branch(state, repo_path) do
    case git(repo_path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, "HEAD"} ->
        %{state | detached_head?: true, branch: nil}

      {:ok, name} when is_binary(name) and name != "" ->
        %{state | branch: name, detached_head?: false}

      _ ->
        # Empty/unborn repo — HEAD points at unborn branch.
        case git(repo_path, ["symbolic-ref", "--short", "HEAD"]) do
          {:ok, name} when is_binary(name) and name != "" ->
            %{state | branch: name, detached_head?: false}

          _ ->
            state
        end
    end
  end

  defp set_head_sha(state, repo_path) do
    case git(repo_path, ["rev-parse", "--short", "HEAD"]) do
      {:ok, sha} when is_binary(sha) and sha != "" -> %{state | head_sha: sha}
      _ -> state
    end
  end

  defp set_origin_url(state, repo_path) do
    case git(repo_path, ["remote", "get-url", "origin"]) do
      {:ok, url} when is_binary(url) and url != "" -> %{state | origin_url: url}
      _ -> state
    end
  end

  defp set_upstream_and_counts(state, repo_path) do
    case git(repo_path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) do
      {:ok, upstream} when is_binary(upstream) and upstream != "" ->
        {behind, ahead} = ahead_behind(repo_path)
        %{state | upstream: upstream, ahead: ahead, behind: behind}

      _ ->
        state
    end
  end

  # `git rev-list --left-right --count <upstream>...HEAD` prints
  # "<behind>\t<ahead>". Either side is `0` when nothing diverges.
  defp ahead_behind(repo_path) do
    case git(repo_path, ["rev-list", "--left-right", "--count", "@{u}...HEAD"]) do
      {:ok, line} ->
        case String.split(line, ~r/\s+/, trim: true) do
          [behind, ahead] -> {to_int(behind), to_int(ahead)}
          _ -> {0, 0}
        end

      _ ->
        {0, 0}
    end
  end

  defp set_dirty(state, repo_path) do
    case git(repo_path, ["status", "--porcelain"]) do
      {:ok, ""} -> %{state | dirty?: false}
      {:ok, _output} -> %{state | dirty?: true}
      _ -> state
    end
  end

  # Best-effort detection via marker files inside the git directory.
  # Resolves worktree indirection by asking git for `--git-dir`.
  defp set_in_progress(state, repo_path) do
    case git(repo_path, ["rev-parse", "--git-dir"]) do
      {:ok, git_dir_rel} ->
        git_dir = absolutize(git_dir_rel, repo_path)
        %{state | in_progress: detect_in_progress(git_dir)}

      _ ->
        state
    end
  end

  defp detect_in_progress(git_dir) do
    cond do
      File.exists?(Path.join(git_dir, "MERGE_HEAD")) -> :merge
      File.dir?(Path.join(git_dir, "rebase-merge")) -> :rebase
      File.dir?(Path.join(git_dir, "rebase-apply")) -> :rebase
      File.exists?(Path.join(git_dir, "CHERRY_PICK_HEAD")) -> :cherry_pick
      File.exists?(Path.join(git_dir, "REVERT_HEAD")) -> :revert
      File.exists?(Path.join(git_dir, "BISECT_LOG")) -> :bisect
      true -> :none
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp git(repo_path, args) do
    case System.cmd("git", ["-C", repo_path] ++ args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, status, String.trim(output)}
    end
  rescue
    ErlangError -> {:error, :exec_failed, ""}
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp absolutize(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path)
  end
end
