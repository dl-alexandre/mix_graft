defmodule Graft.Link.Plan.Change do
  @moduledoc """
  A single proposed change in a `Graft.Link.Plan`.

  Represents one rewrite of one dep in one consumer repo. Pure data —
  building a `Change` performs no writes (the `Plan` builder reads the
  consumer's `mix.exs` once to compute hashes and stringified dep ASTs,
  but does not modify it).

  Hashes flank the rewrite: `mix_exs_before_hash` is what the file
  currently is, `proposed_mix_exs_after_hash` is what it would be after
  applying this change. The Runner uses these for atomicity and for
  recording state.
  """

  @type t :: %__MODULE__{
          repo: atom(),
          repo_path: Path.t(),
          target_app: atom(),
          dependency_source_before: String.t(),
          dependency_source_after: String.t(),
          mix_exs_before_hash: String.t(),
          proposed_mix_exs_after_hash: String.t(),
          changed?: boolean()
        }

  defstruct [
    :repo,
    :repo_path,
    :target_app,
    :dependency_source_before,
    :dependency_source_after,
    :mix_exs_before_hash,
    :proposed_mix_exs_after_hash,
    changed?: false
  ]
end
