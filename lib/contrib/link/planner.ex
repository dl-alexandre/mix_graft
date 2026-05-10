defmodule Contrib.Link.Planner do
  @moduledoc """
  Builds a structured change plan for a `link.on` or `link.off` operation.

  The plan is what `--dry-run` emits and what the Runner executes.
  Both modes share this construction code; the only difference is
  whether the Runner writes the changes.

  ## Workspace fence

  The Planner asserts every target path is within a manifest-listed
  repo before producing a plan. Mutations outside the workspace fence
  are not representable.
  """

  alias Contrib.Workspace

  @type change ::
          %{
            kind: :rewrite_dep,
            repo: atom(),
            dep: atom(),
            mix_exs_path: Path.t(),
            preimage: String.t(),
            replacement: String.t()
          }
          | %{kind: :run_mix, repo: atom(), command: String.t()}

  @type plan :: %{
          operation: :link_on | :link_off,
          packages: [atom()],
          changes: [change()],
          warnings: [String.t()]
        }

  @spec plan_link_on(Workspace.t(), [atom()]) :: {:ok, plan()} | {:error, term()}
  def plan_link_on(_snapshot, _packages), do: {:error, :not_implemented}

  @spec plan_link_off(Workspace.t(), [atom()]) :: {:ok, plan()} | {:error, term()}
  def plan_link_off(_snapshot, _packages), do: {:error, :not_implemented}
end
