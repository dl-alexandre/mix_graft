defmodule Graft.Safety do
  @moduledoc """
  Centralised safety invariants for graft operations.

  All filesystem-side effects go through these checks. No other module
  should re-implement confinement or traversal rules independently.
  """

  alias Graft.Error

  @doc """
  Recursively resolve symlinks in `path`, returning the canonical
  absolute path.

  Follows each symlink component-by-component and detects loops.  For
  non-existent tail components it falls back to `Path.expand/1`
  because a path that does not yet exist cannot be a symlink escape.

  Returns `{:ok, canonical_path}` or `{:error, reason}`.
  """
  @max_symlink_depth 40

  @spec real_path(Path.t()) :: {:ok, Path.t()} | {:error, atom()}
  def real_path(path) do
    abs = Path.expand(path)
    segments = Path.split(abs)
    do_real_path(segments, "/", 0)
  end

  defp do_real_path([], current, _depth) do
    {:ok, current}
  end

  defp do_real_path(["/" | rest], _current, depth) do
    do_real_path(rest, "/", depth)
  end

  defp do_real_path([segment | rest], current, depth) do
    if depth > @max_symlink_depth do
      {:error, :loop}
    else
      current = Path.join(current, segment)

      case :file.read_link(String.to_charlist(current)) do
        {:ok, target} ->
          target_str = List.to_string(target)

          resolved =
            if Path.type(target_str) == :relative do
              Path.join(Path.dirname(current), target_str) |> Path.expand()
            else
              Path.expand(target_str)
            end

          new_segments = Path.split(resolved) ++ rest
          do_real_path(new_segments, "/", depth + 1)

        {:error, :einval} ->
          do_real_path(rest, current, depth)

        {:error, :enoent} ->
          expanded = Path.join([current | rest]) |> Path.expand()
          {:ok, expanded}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verify that `path` is physically inside `base`. Used to prevent
  symlink or write operations from escaping the graft root.

  Returns `:ok` or `{:error, Error.t()}`.
  """
  @spec within_root?(Path.t(), Path.t()) :: :ok | {:error, Error.t()}
  def within_root?(path, base) do
    abs_path = Path.expand(path)
    abs_base = Path.expand(base)

    # Note: Path.expand/1 normalizes . and .. but does NOT follow
    # symlinks.  A symlink inside the workspace that points outside
    # the root will pass this check.  Callers that need to follow
    # symlinks (e.g. before writing into a potentially symlinked
    # sub-directory) should use `real_path/1` first.

    if String.starts_with?(abs_path, abs_base <> "/") or abs_path == abs_base do
      :ok
    else
      {:error,
       Error.new(
         :runner_fence_violation,
         "Path #{path} escapes permitted root #{base}"
       )}
    end
  end

  @doc """
  Verify that a repo name cannot be used to perform path traversal.

  Rejects names containing `..`, `/`, `\\`, or the empty string.
  """
  @spec valid_repo_name?(atom() | String.t()) :: :ok | {:error, Error.t()}
  def valid_repo_name?(name) when is_atom(name) do
    valid_repo_name?(Atom.to_string(name))
  end

  def valid_repo_name?(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, Error.new(:runner_write_failed, "Repo name cannot be empty")}

      String.contains?(name, "..") or String.contains?(name, "/") or
          String.contains?(name, "\\") ->
        {:error,
         Error.new(
           :runner_write_failed,
           "Repo name '#{name}' contains path traversal characters"
         )}

      true ->
        :ok
    end
  end

  @doc """
  Combined check: a path constructed from `base/name` is safe.

  Returns `{:ok, resolved_path}` or `{:error, Error.t()}`.
  """
  @spec resolve_managed_path(Path.t(), atom() | String.t()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def resolve_managed_path(base, name) do
    with :ok <- valid_repo_name?(name),
         resolved = Path.join(base, Atom.to_string(name)),
         :ok <- within_root?(resolved, base) do
      {:ok, resolved}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Check whether the graft root itself is in an allowed location.

  For v1, the root must be inside the system temp directory or inside
  the current working directory. This prevents accidental writes to
  system directories (`/`, `/usr`, `/home`, etc.).
  """
  @spec allowed_root?(Path.t()) :: :ok | {:error, Error.t()}
  def allowed_root?(graft_root) do
    abs_root = Path.expand(graft_root)
    tmp_dir = System.tmp_dir!() |> String.trim_trailing("/")
    cwd = Path.expand(File.cwd!())

    cond do
      String.starts_with?(abs_root, tmp_dir <> "/") or abs_root == tmp_dir ->
        :ok

      String.starts_with?(abs_root, cwd <> "/") or abs_root == cwd ->
        :ok

      true ->
        {:error,
         Error.new(
           :runner_fence_violation,
           "Graft root #{graft_root} must be inside temp directory (#{tmp_dir}) or current working directory (#{cwd}) for safety"
         )}
    end
  end
end
