defmodule Graft.Link.Off.Runner do
  @moduledoc """
  Applies a `Graft.Link.Off.Plan` transactionally.

  ## Algorithm

    1. For each restoration, in plan order:
       a. Read consumer mix.exs.
       b. Verify SHA-256 equals `mix_exs_after_hash` (the post-link
          hash recorded by `link.on`). Tampering or stale state aborts
          with `:off_hash_mismatch`.
       c. Replace `replacement` literally with `preimage`.
       d. Verify the result's SHA-256 equals `mix_exs_before_hash`
          (sanity — the original pre-link hash). Mismatch is also
          `:off_hash_mismatch`.
       e. Atomically write (write-tmp + rename).
       f. Push `(restoration, original_contents)` onto rollback stack.
    2. Save the pruned state (`plan.remaining_entries`) — or delete the
       state file when the list is empty. State update is itself
       transactional: failure rolls back every restored mix.exs.
    3. On any restore failure, walk the rollback stack LIFO and restore
       in-memory originals.

  Restoration is always *literal* — Off never reasons about AST. The
  only authority over what gets restored is the recorded preimage.
  """

  alias Graft.{Error, Lock, State}
  alias Graft.Link.Off.Plan
  alias Graft.Link.Off.Plan.Restoration
  alias Graft.Link.Off.Runner.Result

  @temp_suffix ".graft.tmp"

  @spec run(Plan.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%Plan{} = plan) do
    Lock.with_lock(plan.workspace_root, fn -> do_run(plan) end)
  end

  defp do_run(%Plan{} = plan) do
    start_time = System.monotonic_time(:millisecond)

    case restore_all(plan.restorations) do
      {:ok, applied} ->
        case persist_state(plan) do
          {:ok, deleted?} ->
            {:ok, build_result(applied, plan, deleted?, start_time)}

          {:error, %Error{} = err} ->
            finalize_rollback(err, applied)
        end

      {:error, %Error{} = err, applied_so_far} ->
        finalize_rollback(err, applied_so_far)
    end
  end

  ## ─── Restore phase ──────────────────────────────────────────────────

  defp restore_all(restorations) do
    Enum.reduce_while(restorations, {:ok, []}, fn r, {:ok, applied_rev} ->
      case restore_one(r) do
        {:ok, original} ->
          {:cont, {:ok, [{r, original} | applied_rev]}}

        {:error, %Error{} = err} ->
          {:halt, {:error, err, Enum.reverse(applied_rev)}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp restore_one(%Restoration{} = r) do
    with {:ok, current} <- read_file(r.mix_exs_path, r),
         :ok <- verify_after_hash(current, r),
         {:ok, restored} <- compute_restore(current, r),
         :ok <- verify_before_hash(restored, r),
         :ok <- write_atomic(r.mix_exs_path, restored) do
      {:ok, current}
    end
  end

  defp read_file(path, r) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Error.new(
           :off_restore_failed,
           "Could not read #{path}: #{:file.format_error(reason)}",
           %{repo: r.repo, path: path, reason: reason, phase: :read}
         )}
    end
  end

  defp verify_after_hash(contents, %Restoration{} = r) do
    actual = State.hash_contents(contents)

    if actual == r.mix_exs_after_hash do
      :ok
    else
      {:error,
       Error.new(
         :off_hash_mismatch,
         "Pre-restore hash mismatch for #{r.repo} (#{r.mix_exs_path}): file has changed since link.on",
         %{
           repo: r.repo,
           expected: r.mix_exs_after_hash,
           actual: actual,
           phase: :before_restore
         }
       )}
    end
  end

  defp compute_restore(current, %Restoration{} = r) do
    {:ok, String.replace(current, r.replacement, r.preimage)}
  end

  defp verify_before_hash(restored, %Restoration{} = r) do
    actual = State.hash_contents(restored)

    if actual == r.mix_exs_before_hash do
      :ok
    else
      {:error,
       Error.new(
         :off_hash_mismatch,
         "Post-restore hash mismatch for #{r.repo}: literal restoration diverged from recorded preimage",
         %{
           repo: r.repo,
           expected: r.mix_exs_before_hash,
           actual: actual,
           phase: :after_restore
         }
       )}
    end
  end

  ## ─── Atomic write ───────────────────────────────────────────────────

  defp write_atomic(path, contents) do
    tmp = path <> @temp_suffix

    with :ok <- write_temp(tmp, contents),
         :ok <- rename(tmp, path) do
      :ok
    else
      {:error, %Error{}} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp write_temp(tmp, contents) do
    case File.write(tmp, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :off_restore_failed,
           "Failed to write #{tmp}: #{:file.format_error(reason)}",
           %{path: tmp, reason: reason, phase: :write_temp}
         )}
    end
  end

  defp rename(tmp, path) do
    case File.rename(tmp, path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :off_restore_failed,
           "Failed to rename #{tmp} → #{path}: #{:file.format_error(reason)}",
           %{from: tmp, to: path, reason: reason, phase: :rename}
         )}
    end
  end

  ## ─── State persistence (after every restore succeeds) ───────────────

  # Returns `{:ok, deleted?}` or `{:error, Error}`.
  defp persist_state(%Plan{remaining_entries: []} = plan) do
    path = State.state_path(plan.workspace_root)

    case File.exists?(path) do
      false ->
        {:ok, false}

      true ->
        case File.rm(path) do
          :ok ->
            {:ok, true}

          {:error, reason} ->
            {:error,
             Error.new(
               :off_state_update_failed,
               "Failed to delete #{path}: #{:file.format_error(reason)}",
               %{path: path, reason: reason}
             )}
        end
    end
  end

  defp persist_state(%Plan{} = plan) do
    new_state = %State{
      version: State.schema_version(),
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      entries: plan.remaining_entries
    }

    case State.save(plan.workspace_root, new_state) do
      :ok ->
        {:ok, false}

      {:error, %Error{} = err} ->
        {:error,
         Error.new(
           :off_state_update_failed,
           "State update failed: #{err.message}",
           %{cause: err.kind, message: err.message}
         )}
    end
  end

  ## ─── Result + rollback ──────────────────────────────────────────────

  defp build_result(applied, plan, deleted?, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    %Result{
      restored: Enum.map(applied, fn {r, _} -> r end),
      rolled_back: [],
      remaining_entries: length(plan.remaining_entries),
      remaining_target_apps: plan.remaining_target_apps,
      state_path: State.state_path(plan.workspace_root),
      state_deleted?: deleted?,
      duration_ms: duration
    }
  end

  defp finalize_rollback(original_err, applied) do
    case rollback(applied) do
      :ok ->
        {:error, original_err}

      {:rollback_failures, failures} ->
        {:error,
         Error.new(
           :off_restore_failed,
           "Rollback failed for #{length(failures)} repo(s) after error: #{original_err.message}",
           %{
             original_error_kind: original_err.kind,
             original_error_message: original_err.message,
             rollback_failures:
               Enum.map(failures, fn {r, e} ->
                 %{repo: r.repo, message: e.message}
               end)
           }
         )}
    end
  end

  defp rollback(applied) do
    failures =
      applied
      |> Enum.reverse()
      |> Enum.reduce([], fn {r, original}, acc ->
        case write_atomic(r.mix_exs_path, original) do
          :ok -> acc
          {:error, %Error{} = e} -> [{r, e} | acc]
        end
      end)

    case failures do
      [] -> :ok
      _ -> {:rollback_failures, failures}
    end
  end
end
