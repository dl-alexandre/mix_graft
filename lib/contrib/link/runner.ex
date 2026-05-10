defmodule Contrib.Link.Runner do
  @moduledoc """
  Executes a plan from `Contrib.Link.Planner` transactionally.

  Atomicity contract: if any step fails, all writes performed earlier
  in the run are rolled back from the recorded preimage. The workspace
  never ends in a partially-linked state.

  Asserts the workspace fence (every write target is within a
  manifest-listed repo) before mutating.
  """

  alias Contrib.Link.Planner

  @spec run(Planner.plan()) :: {:ok, Planner.plan()} | {:error, term()}
  def run(_plan), do: {:error, :not_implemented}
end
