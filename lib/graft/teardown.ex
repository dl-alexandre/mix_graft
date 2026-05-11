defmodule Graft.Teardown do
  @moduledoc """
  Safely remove materialized graft entries.

  Only `:managed` repos inside the graft root are touched. `:external`
  source repos are **never** deleted. This is a hard invariant: teardown
  can only remove what materialization created.

  Teardown is idempotent: removing an already-removed entry is a no-op.

  Safety: teardown refuses to remove a managed path that is not a symlink,
  unless it is an empty directory. This prevents accidental deletion of
  real source trees.

  All removals are gated by `Graft.Safety`.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Safety

  @type result :: :ok | {:error, Error.t()}

  @doc """
  Tear down a single materialized repo entry.

  If `repo.ownership` is `:external`, returns `:ok` immediately (nothing
  to tear down). If the repo is `:managed`, removes the symlink inside
  `graft_root`. Never touches `repo.absolute_path`.

  ## Safety rules

    * If the path does not exist → `:ok` (idempotent).
    * If the path is a symlink → remove it.
    * If the path is an empty directory → remove it (allows cleanup of
      the parent directory created by `File.mkdir_p!`).
    * If the path is a non-empty directory or regular file → **refuse**.
    * If the path name contains path-traversal characters → **refuse**.
    * If the resolved path escapes `graft_root` → **refuse**.
  """
  @spec teardown_repo(Workspace.Repo.t(), Path.t()) :: result()
  def teardown_repo(%Workspace.Repo{ownership: :external}, _graft_root), do: :ok

  def teardown_repo(%Workspace.Repo{name: name}, graft_root) when is_binary(graft_root) do
    with :ok <- Safety.allowed_root?(graft_root),
         {:ok, link_path} <- Safety.resolve_managed_path(graft_root, name) do
      cond do
        not File.exists?(link_path) ->
          # Already gone — idempotent
          :ok

        symlink?(link_path) ->
          case File.rm(link_path) do
            :ok ->
              :ok

            {:error, reason} ->
              {:error,
               Error.new(
                 :runner_rollback_failed,
                 "Failed to remove symlink #{link_path}: #{:file.format_error(reason)}"
               )}
          end

        File.dir?(link_path) ->
          case File.ls(link_path) do
            {:ok, []} ->
              case File.rmdir(link_path) do
                :ok ->
                  :ok

                {:error, reason} ->
                  {:error,
                   Error.new(
                     :runner_rollback_failed,
                     "Failed to remove empty directory #{link_path}: #{:file.format_error(reason)}"
                   )}
              end

            {:ok, _entries} ->
              {:error,
               Error.new(
                 :runner_rollback_failed,
                 "Refusing to remove #{link_path}: it is a non-empty directory. Manual cleanup required."
               )}
          end

        true ->
          {:error,
           Error.new(
             :runner_rollback_failed,
             "Refusing to remove #{link_path}: it is a regular file, not a symlink. Manual cleanup required."
           )}
      end
    end
  end

  @doc """
  Tear down all managed repos in a workspace snapshot from the graft root.

  Returns `:ok` if all teardowns succeed, or the first error encountered.
  """
  @spec teardown_workspace(Workspace.t(), Path.t()) :: result()
  def teardown_workspace(%Workspace{repos: repos}, graft_root) when is_binary(graft_root) do
    managed = Enum.filter(repos, &(&1.ownership == :managed))

    Enum.reduce(managed, :ok, fn repo, acc ->
      case acc do
        :ok -> teardown_repo(repo, graft_root)
        {:error, _} = err -> err
      end
    end)
  end

  defp symlink?(path) do
    case File.read_link(path) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
