defmodule Graft.Link.Off.Runner.Result do
  @moduledoc """
  Outcome of a successful `Graft.Link.Off.Runner.run/2` call.
  """

  alias Graft.Link.Off.Plan.Restoration

  @type t :: %__MODULE__{
          restored: [Restoration.t()],
          rolled_back: [Restoration.t()],
          remaining_entries: non_neg_integer(),
          remaining_target_apps: [atom()],
          state_path: Path.t(),
          state_deleted?: boolean(),
          duration_ms: non_neg_integer()
        }

  defstruct restored: [],
            rolled_back: [],
            remaining_entries: 0,
            remaining_target_apps: [],
            state_path: nil,
            state_deleted?: false,
            duration_ms: 0
end
