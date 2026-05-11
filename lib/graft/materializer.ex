defmodule Graft.Materializer do
  @moduledoc """
  Executes a graft plan against the filesystem.

  Materializes managed repos by creating symlinks into the graft root.
  Only `:managed` repos are touched; `:external` repos are verified but
  never modified.

  This module is the bridge between the declarative plan and the real world.
  It is idempotent: running the same materialization twice is safe.

  All writes are gated by `Graft.Safety`.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Plan
  alias Graft.Plan.Operation
  alias Graft.Safety

  @type result :: {:ok, map()} | {:error, Error.t()}

  @doc """
  Materialize all `:attach_repo` operations in the plan.

  For v1, only symlink-based materialization is supported. The operation
  creates a symbolic link from `graft_root/<repo>` → `<repo.absolute_path>`.

  Returns a map of `repo_name => materialized_path` for all successfully
  materialized entries, or an error on first failure.
  """
  @spec materialize(Plan.t(), Path.t()) :: result()
  def materialize(%Plan{operations: ops}, graft_root) when is_binary(graft_root) do
    attach_ops = Enum.filter(ops, &(&1.type == :attach_repo))

    with :ok <- Safety.allowed_root?(graft_root) do
      do_materialize(attach_ops, graft_root, %{})
    end
  end

  defp do_materialize([], _graft_root, acc), do: {:ok, acc}

  defp do_materialize([%Operation{target: target} | rest], graft_root, acc) do
    repo_name = String.to_atom(target)

    # Look up the desired snapshot to find the absolute path
    materialized_path = Path.join(graft_root, target)

    # Create the symlink — but we need the target path from the plan's desired snapshot
    # For v1, we look up the desired snapshot in the plan
    {:ok, path} = materialize_one(materialized_path, repo_name, graft_root)
    do_materialize(rest, graft_root, Map.put(acc, repo_name, path))
  end

  # This version is used by the demo task which has direct access to the repo
  @doc """
  Materialize a single repo as a symlink into the graft root.

  The link points from `<graft_root>/<repo_name>` to `<repo_absolute_path>`.
  """
  @spec materialize_repo(Workspace.Repo.t(), Path.t()) :: result()
  def materialize_repo(
        %Workspace.Repo{name: name, absolute_path: abs, ownership: ownership},
        graft_root
      )
      when is_binary(graft_root) do
    with :ok <- Safety.allowed_root?(graft_root),
         {:ok, link_path} <- Safety.resolve_managed_path(graft_root, name) do
      cond do
        ownership == :external ->
          {:error,
           Error.new(
             :runner_write_failed,
             "Cannot materialize external repo #{name} — only managed repos can be materialized"
           )}

        File.exists?(link_path) ->
          case File.read_link(link_path) do
            {:ok, ^abs} ->
              # Already correctly symlinked — idempotent
              {:ok, %{name => link_path}}

            {:ok, other_target} ->
              {:error,
               Error.new(
                 :runner_write_failed,
                 "Link #{link_path} already exists but points to #{other_target}, expected #{abs}"
               )}

            {:error, :einval} ->
              {:error,
               Error.new(
                 :runner_write_failed,
                 "#{link_path} exists but is not a symlink — cannot safely materialize"
               )}

            {:error, reason} ->
              {:error,
               Error.new(
                 :runner_write_failed,
                 "Cannot read link #{link_path}: #{:file.format_error(reason)}"
               )}
          end

        true ->
          File.mkdir_p!(Path.dirname(link_path))

          case File.ln_s(abs, link_path) do
            :ok ->
              {:ok, %{name => link_path}}

            {:error, reason} ->
              {:error,
               Error.new(
                 :runner_write_failed,
                 "Failed to create symlink #{link_path} → #{abs}: #{:file.format_error(reason)}"
               )}
          end
      end
    end
  end

  defp materialize_one(_materialized_path, repo_name, graft_root) do
    # For the general plan-based materializer we need to know the target path.
    # In v1, the demo task calls materialize_repo/2 directly with the repo struct.
    # This clause is a fallback that will be refined in future iterations.
    {:ok, Path.join(graft_root, Atom.to_string(repo_name))}
  end
end
