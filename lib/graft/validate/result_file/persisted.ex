defmodule Graft.Validate.ResultFile.Persisted do
  @moduledoc """
  Decoded shape of `.graft/validate.result.json`. Lean by design —
  the verdict, fingerprint, and per-repo status are what agents and
  downstream commands ask about. Full command transcripts live in
  `.graft/validate.log`, not here.
  """

  @type repo_status :: :passed | :failed | :skipped
  @type first_failure ::
          %{
            repo: atom(),
            command_kind: atom(),
            failure_category: atom(),
            summary: String.t()
          }
          | nil

  @type t :: %__MODULE__{
          version: pos_integer(),
          generated_at: String.t(),
          workspace_root: Path.t(),
          target_apps: [atom()],
          affected_repos: [atom()],
          passed?: boolean(),
          passed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          first_failure: first_failure(),
          repo_statuses: %{atom() => repo_status()},
          fingerprint: %{atom() => String.t()},
          log_path: Path.t() | nil
        }

  defstruct version: 1,
            generated_at: nil,
            workspace_root: nil,
            target_apps: [],
            affected_repos: [],
            passed?: false,
            passed_count: 0,
            failed_count: 0,
            skipped_count: 0,
            duration_ms: 0,
            first_failure: nil,
            repo_statuses: %{},
            fingerprint: %{},
            log_path: nil
end
