defmodule Graft.Lock do
  @moduledoc """
  Single-writer filesystem guard for a Graft workspace.

  A lock is an O_EXCL file at `<root>/.graft/lock`. Acquisition is
  atomic at the filesystem level — `:file.open(path, [:write, :exclusive])`
  fails with `:eexist` if any other process already holds it.

  ## Scope

  This is intentionally simple:

    * No distributed locking.
    * No retry, wait, or timeout.
    * No stale-lock detection (a crashed process leaves the lock in
      place; future milestones may add liveness checks).

  Use only to prevent two `mix graft.*` mutating commands in the same
  workspace from running concurrently on one machine.
  """

  alias Graft.Error

  @lock_dir ".graft"
  @lock_file "lock"

  @doc "Conventional lock path under `root`."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(root), do: Path.join([root, @lock_dir, @lock_file])

  @doc """
  Acquire the workspace lock, run `fun`, and release the lock — even if
  `fun` raises or returns `{:error, _}`. Returns whatever `fun` returns,
  or `{:error, %Graft.Error{kind: :workspace_locked}}` if the lock
  could not be acquired.
  """
  @spec with_lock(Path.t(), (-> any())) :: any()
  def with_lock(root, fun) when is_binary(root) and is_function(fun, 0) do
    path = lock_path(root)

    case acquire(path) do
      :ok ->
        try do
          fun.()
        after
          _ = File.rm(path)
        end

      {:error, %Error{}} = err ->
        err
    end
  end

  @doc false
  def acquire(path) do
    with :ok <- ensure_parent(Path.dirname(path)),
         :ok <- open_exclusive(path) do
      :ok
    end
  end

  defp ensure_parent(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :workspace_locked,
           "Failed to prepare lock directory #{dir}: #{:file.format_error(reason)}",
           %{path: dir, reason: reason, phase: :prepare}
         )}
    end
  end

  defp open_exclusive(path) do
    case :file.open(path, [:write, :exclusive, :raw]) do
      {:ok, fd} ->
        :file.write(
          fd,
          "pid=#{:os.getpid()} acquired_at=#{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
        )

        :file.close(fd)
        :ok

      {:error, :eexist} ->
        {:error,
         Error.new(
           :workspace_locked,
           "Workspace already locked at #{path} — another contrib mutation is in progress",
           %{path: path, phase: :acquire}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :workspace_locked,
           "Failed to acquire lock at #{path}: #{:file.format_error(reason)}",
           %{path: path, reason: reason, phase: :acquire}
         )}
    end
  end
end
