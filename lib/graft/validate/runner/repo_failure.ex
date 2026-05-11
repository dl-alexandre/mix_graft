defmodule Graft.Validate.Runner.RepoFailure do
  @moduledoc """
  The single failure that the contributor should look at first.

  Computed by the runner as the *earliest* failure in topological order
  — not a list, not the last, not the worst. The whole point is to
  remove triage cost: one place to look, every time.

  `pointer` carries the exact `(repo_path, command, log_path)` triple so
  a human can jump to a terminal or editor and an agent can dispatch a
  fix attempt without re-deriving anything.
  """

  alias Graft.Validate.Runner.CommandOutcome

  @type t :: %__MODULE__{
          repo: atom(),
          command_kind: Graft.Validate.Plan.Command.kind(),
          failure_category: CommandOutcome.failure_category(),
          summary: String.t(),
          log_excerpt: String.t(),
          pointer: %{
            repo_path: Path.t(),
            command: String.t(),
            log_path: Path.t() | nil
          }
        }

  defstruct [:repo, :command_kind, :failure_category, :summary, :log_excerpt, :pointer]
end
