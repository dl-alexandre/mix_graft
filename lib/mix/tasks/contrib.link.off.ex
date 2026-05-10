defmodule Mix.Tasks.Contrib.Link.Off do
  @shortdoc "Revert sibling-repo path links recorded by contrib.link.on"

  @moduledoc """
  Restores `mix.exs` files rewritten by `contrib.link.on` from the
  recorded preimage in `.contrib/state.json`. Refuses if any target
  file's current SHA-256 differs from the recorded post-rewrite hash;
  pass `--force` to override.

      mix contrib.link.off PKG [PKG…]
      mix contrib.link.off req_llm --dry-run
      mix contrib.link.off req_llm --force
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("contrib.link.off: not implemented")
  end
end
