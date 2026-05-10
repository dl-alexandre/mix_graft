defmodule Mix.Tasks.Contrib.Link.On do
  @shortdoc "Link sibling repos to local paths for joint development"

  @moduledoc """
  Transitively rewrites `mix.exs` in every sibling that depends on
  the named package(s) to use a `path:` dep instead of hex. Atomic
  across repos: rolls back on failure.

      mix contrib.link.on PKG [PKG…]
      mix contrib.link.on req_llm --dry-run
      mix contrib.link.on req_llm --json

  See `mix help contrib.link.off` to revert.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("contrib.link.on: not implemented")
  end
end
