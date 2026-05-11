defmodule Graft.Link.Runner do
  @moduledoc """
  Applies a `Graft.Link.Plan` transactionally.

  ## Atomicity contract

  Either every changed entry is applied **and** state.json is persisted,
  or every successfully-applied entry is rolled back to its byte-for-byte
  preimage. There is no partial-success end state.

  ## Algorithm

    1. Reject any change whose `repo_path` lies outside the plan's
       declared `workspace_root` (defence-in-depth — Plan already
       enforces this fence).
    2. Filter to effective changes (`changed?: true`); no-ops are
       skipped safely.
    3. For each effective change, in order:
       a. Read the consumer `mix.exs`.
       b. Verify its SHA-256 equals `change.mix_exs_before_hash`.
       c. Apply the literal `dependency_source_before → dependency_source_after`
          rewrite via `String.replace/3`.
       d. Verify the result's SHA-256 equals `change.proposed_mix_exs_after_hash`.
       e. Atomically write the new contents (write-tmp + rename).
       f. Push `(change, original_contents)` onto the rollback stack.
    4. Persist `Graft.State.from_plan(plan)`.
    5. On any failure in step 3 or 4, walk the rollback stack in LIFO
       order, restoring each consumer's `mix.exs` from its in-memory
       original.

  ## Why a literal find/replace and not a re-rewrite?

  The plan carries the post-rewrite hash. After applying the literal
  replacement we hash the result and verify equality with the planned
  hash. Any divergence (duplicate dep tuple appearing in a docstring,
  manual edit, etc.) shows up as a hash mismatch and aborts before
  writing. This keeps the runner free of Sourceror or path-resolution
  logic — those are planning-time concerns.

  ## Filesystem rules

    * Atomic writes: `File.write/2` to `<path>.graft.tmp` followed by
      `File.rename/2`. POSIX rename is atomic within a filesystem.
    * Temp files are removed if any preceding step fails.

  No git, no `mix deps.unlock`, no `mix deps.get`. Those integrate in
  later milestones.
  """

  alias Graft.{Error, Lock, State}
  alias Graft.Link.{Plan, Runner.Result}
  alias Graft.Link.Plan.Change

  @temp_suffix ".graft.tmp"

  @doc """
  Apply `plan` transactionally. Returns `{:ok, %Result{}}` on full
  success or `{:error, %Graft.Error{}}` on any failure (rollback is
  attempted automatically).
  """
  @spec run(Plan.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%Plan{} = plan, opts \\ []) when is_list(opts) do
    start_time = System.monotonic_time(:millisecond)

    Lock.with_lock(plan.workspace_root, fn ->
      with :ok <- check_fence(plan),
           :ok <- preflight_state(plan) do
        apply_and_save(plan, start_time)
      end
    end)
  end

  ## ─── Pre-flight: refuse mutation if existing state is corrupt ──────

  defp preflight_state(%Plan{changes: changes} = plan) do
    case Enum.any?(changes, & &1.changed?) do
      false ->
        :ok

      true ->
        case State.load_or_empty(plan.workspace_root) do
          {:ok, _state} ->
            :ok

          {:error, %Error{} = err} ->
            {:error,
             Error.new(
               :corrupt_state,
               "Refusing to mutate: existing state.json is unreadable: #{err.message}",
               %{cause: err.kind, message: err.message}
             )}
        end
    end
  end

  ## ─── Workspace fence (defence-in-depth) ─────────────────────────────

  defp check_fence(%Plan{workspace_root: root, changes: changes}) do
    case Enum.reject(changes, &inside_root?(&1.repo_path, root)) do
      [] ->
        :ok

      [bad | _] ->
        {:error,
         Error.new(
           :runner_fence_violation,
           "Refusing to mutate #{bad.repo_path}: outside workspace root #{root}",
           %{repo: bad.repo, repo_path: bad.repo_path, workspace_root: root}
         )}
    end
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  ## ─── Apply + persist orchestration ──────────────────────────────────

  defp apply_and_save(plan, start_time) do
    case apply_changes(plan) do
      {:ok, applied} ->
        case maybe_save_state(plan, applied) do
          :ok -> {:ok, build_result(applied, plan, start_time)}
          {:error, %Error{} = err} -> finalize_rollback(err, applied)
        end

      {:error, %Error{} = err, applied_so_far} ->
        finalize_rollback(err, applied_so_far)
    end
  end

  defp build_result(applied, plan, start_time) do
    duration = System.monotonic_time(:millisecond) - start_time

    %Result{
      applied_changes: Enum.map(applied, fn {c, _} -> c end),
      rolled_back_changes: [],
      state_path: State.state_path(plan.workspace_root),
      duration_ms: duration
    }
  end

  ## ─── Apply phase ────────────────────────────────────────────────────

  # Returns `{:ok, applied}` where `applied` is `[{change, original}]`
  # in application order. On failure returns `{:error, err, applied}`
  # so the caller can roll back `applied` LIFO.
  defp apply_changes(%Plan{changes: changes}) do
    effective = Enum.filter(changes, & &1.changed?)

    Enum.reduce_while(effective, {:ok, []}, fn change, {:ok, applied_rev} ->
      case apply_one(change) do
        {:ok, original} ->
          {:cont, {:ok, [{change, original} | applied_rev]}}

        {:error, %Error{} = err} ->
          {:halt, {:error, err, Enum.reverse(applied_rev)}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp apply_one(%Change{} = change) do
    mix_exs_path = Path.join(change.repo_path, "mix.exs")

    with {:ok, original} <- read_file(mix_exs_path, change),
         :ok <- verify_before_hash(original, change),
         {:ok, rewritten} <- compute_rewrite(original, change),
         :ok <- verify_after_hash(rewritten, change),
         :ok <- write_atomic(mix_exs_path, rewritten) do
      {:ok, original}
    end
  end

  defp read_file(path, change) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Error.new(
           :runner_write_failed,
           "Could not read #{path}: #{:file.format_error(reason)}",
           %{repo: change.repo, path: path, reason: reason, phase: :read}
         )}
    end
  end

  defp verify_before_hash(contents, %Change{} = change) do
    actual = State.hash_contents(contents)

    if actual == change.mix_exs_before_hash do
      :ok
    else
      {:error,
       Error.new(
         :runner_hash_mismatch,
         "Pre-rewrite hash mismatch for #{change.repo} (#{Path.join(change.repo_path, "mix.exs")}): file has changed since planning",
         %{
           repo: change.repo,
           expected: change.mix_exs_before_hash,
           actual: actual,
           phase: :before
         }
       )}
    end
  end

  defp compute_rewrite(original, %Change{} = change) do
    rewritten =
      String.replace(
        original,
        change.dependency_source_before,
        change.dependency_source_after
      )

    {:ok, rewritten}
  end

  defp verify_after_hash(rewritten, %Change{} = change) do
    actual = State.hash_contents(rewritten)

    if actual == change.proposed_mix_exs_after_hash do
      :ok
    else
      {:error,
       Error.new(
         :runner_hash_mismatch,
         "Post-rewrite hash mismatch for #{change.repo}: literal substitution diverged from the plan",
         %{
           repo: change.repo,
           expected: change.proposed_mix_exs_after_hash,
           actual: actual,
           phase: :after
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
           :runner_write_failed,
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
           :runner_write_failed,
           "Failed to rename #{tmp} → #{path}: #{:file.format_error(reason)}",
           %{from: tmp, to: path, reason: reason, phase: :rename}
         )}
    end
  end

  ## ─── State save (only after every write succeeds) ───────────────────

  defp maybe_save_state(_plan, []), do: :ok

  defp maybe_save_state(plan, _applied) do
    with {:ok, existing} <- load_existing(plan),
         merged = State.merge_with_plan(existing, plan),
         :ok <- save_merged(plan, merged) do
      :ok
    end
  end

  defp load_existing(plan) do
    case State.load_or_empty(plan.workspace_root) do
      {:ok, state} ->
        {:ok, state}

      {:error, %Error{} = err} ->
        {:error,
         Error.new(
           :runner_state_persist_failed,
           "Refusing to overwrite unreadable state: #{err.message}",
           %{cause: err.kind, message: err.message}
         )}
    end
  end

  defp save_merged(plan, merged) do
    case State.save(plan.workspace_root, merged) do
      :ok ->
        :ok

      {:error, %Error{} = err} ->
        {:error,
         Error.new(
           :runner_state_persist_failed,
           "State persist failed: #{err.message}",
           %{cause: err.kind, message: err.message}
         )}
    end
  end

  ## ─── Rollback ───────────────────────────────────────────────────────

  defp finalize_rollback(original_err, applied) do
    case rollback(applied) do
      :ok ->
        {:error, original_err}

      {:rollback_failures, failures} ->
        {:error,
         Error.new(
           :runner_rollback_failed,
           "Rollback failed for #{length(failures)} repo(s) after error: #{original_err.message}",
           %{
             original_error_kind: original_err.kind,
             original_error_message: original_err.message,
             rollback_failures:
               Enum.map(failures, fn {change, e} ->
                 %{repo: change.repo, message: e.message}
               end)
           }
         )}
    end
  end

  # Walk the rollback stack LIFO, restoring each consumer's mix.exs to
  # its recorded preimage. Failures collected and reported.
  defp rollback(applied) do
    failures =
      applied
      |> Enum.reverse()
      |> Enum.reduce([], fn {change, original}, acc ->
        mix_exs_path = Path.join(change.repo_path, "mix.exs")

        case write_atomic(mix_exs_path, original) do
          :ok -> acc
          {:error, %Error{} = e} -> [{change, e} | acc]
        end
      end)

    case failures do
      [] -> :ok
      _ -> {:rollback_failures, failures}
    end
  end
end
