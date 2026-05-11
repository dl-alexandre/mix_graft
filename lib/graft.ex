defmodule Graft do
  @moduledoc """
  Transactional workspace tooling for Elixir OSS contributors.

  Graft treats a directory of cloned sibling Elixir repos as a single
  workspace. Every command derives from `Graft.Workspace.snapshot/0`,
  the canonical data model.

  See `mix help graft.status` to begin.
  """
end
