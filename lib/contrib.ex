defmodule Contrib do
  @moduledoc """
  Transactional workspace tooling for Elixir OSS contributors.

  Contrib treats a directory of cloned sibling Elixir repos as a single
  workspace. Every command derives from `Contrib.Workspace.snapshot/0`,
  the canonical data model.

  See `mix help contrib.status` to begin.
  """
end
