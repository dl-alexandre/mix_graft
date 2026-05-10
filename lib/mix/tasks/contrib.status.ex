defmodule Mix.Tasks.Contrib.Status do
  @shortdoc "Show workspace state across sibling repos"

  @moduledoc """
  Renders a snapshot of the Contrib workspace.

      mix contrib.status
      mix contrib.status --json

  Read-only, side-effect free.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("contrib.status: not implemented")
  end
end
