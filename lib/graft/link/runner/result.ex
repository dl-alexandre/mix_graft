defmodule Graft.Link.Runner.Result do
  @moduledoc """
  Outcome of a successful `Graft.Link.Runner.run/2` call.

  * `applied_changes` — every plan change actually written to disk, in
    application order.
  * `rolled_back_changes` — always `[]` on success. Reserved for future
    partial-success semantics.
  * `state_path` — absolute path to the state file Graft wrote (or
    would have written if the plan was a no-op).
  * `duration_ms` — wall-clock duration of the run, monotonic.
  """

  alias Graft.Link.Plan.Change

  @type t :: %__MODULE__{
          applied_changes: [Change.t()],
          rolled_back_changes: [Change.t()],
          state_path: Path.t(),
          duration_ms: non_neg_integer()
        }

  defstruct applied_changes: [], rolled_back_changes: [], state_path: nil, duration_ms: 0
end
