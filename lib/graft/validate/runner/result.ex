defmodule Graft.Validate.Runner.Result do
  @moduledoc """
  Final outcome of `Graft.Validate.Runner.run/2`.

  `passed?` is the first field: humans and agents pattern-match it at
  depth one. `first_failure` is the *curated* view — the single
  earliest-topological failure that the contributor should look at.
  `outcomes` carries everything else for drill-down.
  """

  alias Graft.Validate.Runner.{RepoFailure, RepoOutcome}

  @type t :: %__MODULE__{
          passed?: boolean(),
          first_failure: RepoFailure.t() | nil,
          outcomes: [RepoOutcome.t()],
          workspace_root: Path.t(),
          target_apps: [atom()],
          affected_repos: [atom()],
          passed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          log_path: Path.t() | nil,
          result_path: Path.t() | nil
        }

  defstruct passed?: false,
            first_failure: nil,
            outcomes: [],
            workspace_root: nil,
            target_apps: [],
            affected_repos: [],
            passed_count: 0,
            failed_count: 0,
            skipped_count: 0,
            duration_ms: 0,
            log_path: nil,
            result_path: nil
end
