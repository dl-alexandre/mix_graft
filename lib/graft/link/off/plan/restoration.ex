defmodule Graft.Link.Off.Plan.Restoration do
  @moduledoc """
  One literal restoration recorded in a `Graft.Link.Off.Plan`.

  Restoration is always *literal* — `replacement` (the path-link tuple
  currently in the consumer's `mix.exs`) is replaced byte-for-byte by
  `preimage` (the original Hex/Git tuple). No AST, no inverse rewrite.
  """

  @type t :: %__MODULE__{
          repo: atom(),
          repo_path: Path.t(),
          target_app: atom(),
          mix_exs_path: Path.t(),
          mix_exs_before_hash: String.t(),
          mix_exs_after_hash: String.t(),
          preimage: String.t(),
          replacement: String.t()
        }

  defstruct [
    :repo,
    :repo_path,
    :target_app,
    :mix_exs_path,
    :mix_exs_before_hash,
    :mix_exs_after_hash,
    :preimage,
    :replacement
  ]
end
