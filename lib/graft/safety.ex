defmodule Graft.Safety do
  @moduledoc """
  Centralised safety invariants for graft operations.

  All filesystem-side effects go through these checks. No other module
  should re-implement confinement or traversal rules independently.

  ## Primitives and when to use them

  Three functions with **different** semantics live here.  Picking the
  wrong one is a security bug.

  | Function | Follows symlinks? | Use when … |
  |----------|-------------------|------------|
  | `within_root?/2` | **No** — lexical only | You need to know whether a *path string* is inside the root.  Safe for creating new symlinks or deleting existing symlink **objects** (not their targets). |
  | `real_path/1` | **Yes** — recursive | You need the canonical path that the OS will resolve *after* following symlinks.  Use **before** writing into a directory that might be a symlink. |
  | `resolve_managed_path/2` | **No** | Convenience wrapper: validates the repo name and checks `within_root?/2`.  Returns the literal path for materialisation. |

  ### Rule of thumb

  * Creating a **new** path (e.g. `File.ln_s/2`) → `within_root?/2` is enough.
  * Writing **into** an existing path (e.g. `git clone`, `File.write!/2`) →
    call `real_path/1` first, then `within_root?/2` on the result.

  ## Examples

      # Lexical containment — does NOT follow symlinks
      iex> Graft.Safety.within_root?("/tmp/link_to_etc", "/tmp")
      :ok   # passes because the path *string* is under /tmp

      # Symlink-aware canonicalisation
      iex> Graft.Safety.real_path("/tmp/link_to_etc")
      {:ok, "/etc"}

      # Combined — write operations should use both
      iex> with {:ok, resolved} <- Graft.Safety.real_path(path),
      ...>      :ok <- Graft.Safety.within_root?(resolved, root) do
      ...>   :safe
      ...> end
  """

  alias Graft.Error

  @doc """
  Recursively resolve symlinks in `path`, returning the canonical
  absolute path.

  Follows each symlink component-by-component and detects loops.  For
  non-existent tail components it falls back to `Path.expand/1`
  because a path that does not yet exist cannot be a symlink escape.

  **Use this before writing into a path that might be a symlink.**
  After resolving, call `within_root?/2` on the result to enforce root
  containment on the *target* rather than on the path string.

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
  Lexical containment: check whether `path` (as a string) is inside `base`.

  **Does NOT follow symlinks.**  It expands `.`, `..`, and normalises the
  path, then performs a prefix check.  This is the correct primitive when
  you are creating a *new* object (symlink, directory) or deleting an
  existing symlink *object*, because you only care about the path string
  itself, not what it might resolve to.

  If you are about to write *into* an existing path (e.g. `git clone`,
  `File.write!`), you **must** call `real_path/1` first and then check
  `within_root?/2` on the resolved result.

  Returns `:ok` or `{:error, Error.t()}`.
  """
  @spec within_root?(Path.t(), Path.t()) :: :ok | {:error, Error.t()}
  def within_root?(path, base) do
    abs_path = Path.expand(path)
    abs_base = Path.expand(base)

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
