defmodule Contrib.Status do
  @moduledoc """
  Renders a `Contrib.Workspace` snapshot as either a human table or
  structured JSON.

  Pure presentation — performs no IO except via the caller's chosen
  output format.
  """

  alias Contrib.Workspace

  @spec render(Workspace.t(), :human | :json) :: iodata()
  def render(_snapshot, _format), do: "not implemented"
end
