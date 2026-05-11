defmodule Graft.Link.Resolver do
  @moduledoc """
  Computes the affected closure of repos for a `link.on` / `link.off`
  operation.

  Models the workspace as a directed graph (cycles are legitimate in
  dev). Cycles emit a warning naming the cycle, not a hard error.
  Topological ordering is applied only to steps that need it (e.g.,
  `mix deps.get` execution order).
  """

  alias Graft.Workspace

  @type closure :: %{
          repos: [atom()],
          execution_order: [atom()],
          cycles: [[atom()]]
        }

  @spec closure(Workspace.t(), [atom()]) :: {:ok, closure()} | {:error, term()}
  def closure(_snapshot, _packages), do: {:error, :not_implemented}
end
