defmodule Graft.Error do
  @moduledoc """
  Structured error returned by Graft's public API.

  Errors carry a machine-readable `kind` so callers (CLI, agents, future
  LiveView UI) can render appropriate messages without parsing strings.
  """

  @type kind ::
          :manifest_not_found
          | :manifest_eval_failed
          | :manifest_invalid_shape
          | :manifest_invalid_field
          | :manifest_duplicate_sibling_name
          | :manifest_duplicate_sibling_path
          | :manifest_sibling_outside_root
          | :rewriter_malformed_source
          | :rewriter_invalid_replacement
          | :rewriter_unknown_dep_shape
          | :plan_target_not_in_workspace
          | :plan_invalid_operation
          | :mutation_not_implemented
          | :state_io_error
          | :state_invalid_json
          | :state_invalid_shape
          | :state_unsupported_version
          | :state_invalid_field
          | :state_unknown_atom
          | :runner_hash_mismatch
          | :runner_write_failed
          | :runner_rollback_failed
          | :runner_state_persist_failed
          | :runner_fence_violation
          | :off_state_missing
          | :off_hash_mismatch
          | :off_workspace_violation
          | :off_restore_failed
          | :off_state_update_failed
          | :off_target_not_in_state
          | :workspace_locked
          | :corrupt_state
          | :atomic_write_failed
          | :validate_target_not_in_workspace
          | :validate_command_failed
          | :validate_executable_not_found
          | :validate_result_unreadable
          | :validate_result_missing
          | :not_implemented

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          details: map()
        }

  defexception [:kind, :message, details: %{}]

  @impl true
  def message(%__MODULE__{message: m}), do: m

  @doc false
  def new(kind, message, details \\ %{}) when is_atom(kind) and is_binary(message) do
    %__MODULE__{kind: kind, message: message, details: details}
  end
end
