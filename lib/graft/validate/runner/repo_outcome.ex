defmodule Graft.Validate.Runner.RepoOutcome do
  @moduledoc """
  Aggregated outcome for one repo in the validate plan.

  `status` is the rollup of the per-command statuses:

    * `:passed` — every command in this repo passed.
    * `:failed` — at least one command failed.
    * `:skipped` — fail-fast aborted before this repo started.

  `:skipped` ≠ `:failed`. Skipped means we never ran; agents and
  contributors must treat the two distinctly.
  """

  alias Graft.Validate.Runner.CommandOutcome

  @type status :: :passed | :failed | :skipped

  @type t :: %__MODULE__{
          repo: atom(),
          repo_path: Path.t(),
          status: status(),
          duration_ms: non_neg_integer(),
          commands: [CommandOutcome.t()]
        }

  defstruct [:repo, :repo_path, :status, duration_ms: 0, commands: []]
end
