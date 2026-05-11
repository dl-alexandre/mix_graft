defmodule Graft.Validate.Runner.CommandOutcome do
  @moduledoc """
  Outcome of a single mix invocation in a validate run.

  v0.1 captures merged stdout+stderr (System.cmd uses `stderr_to_stdout`
  by default for us; the full transcript lives in the run log). The
  `output_tail` is the last ~20 lines of merged output — enough to read
  inline, never enough to drown the result envelope.

  `failure_category` is heuristic and may be `nil` when status is
  `:passed` or `:skipped`. Categories are stable across runs: agents
  branch on them safely.
  """

  @type kind :: Graft.Validate.Plan.Command.kind()
  @type status :: :passed | :failed | :skipped

  @type failure_category ::
          :deps_unresolvable
          | :compile_error
          | :test_failure
          | :command_not_found
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          argv: [String.t()],
          description: String.t(),
          status: status(),
          exit_status: integer() | nil,
          duration_ms: non_neg_integer(),
          output_tail: String.t(),
          failure_category: failure_category() | nil
        }

  defstruct [
    :kind,
    :argv,
    :description,
    :status,
    :exit_status,
    :failure_category,
    duration_ms: 0,
    output_tail: ""
  ]
end
