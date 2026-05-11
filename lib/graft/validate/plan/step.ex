defmodule Graft.Validate.Plan.Step do
  @moduledoc """
  All commands to run inside a single repo, in fixed order. Steps are
  themselves ordered topologically across the plan — dependencies run
  before their consumers.
  """

  alias Graft.Validate.Plan.Command

  @type t :: %__MODULE__{
          repo: atom(),
          repo_path: Path.t(),
          commands: [Command.t()]
        }

  defstruct [:repo, :repo_path, :commands]
end
