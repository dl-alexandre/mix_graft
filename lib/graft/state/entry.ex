defmodule Graft.State.Entry do
  @moduledoc """
  A single recorded rewrite in `.graft/state.json`. Stores everything
  the runner needs to perform a literal restore of the dep tuple in the
  consumer's `mix.exs`, plus SHA-256 hashes flanking the rewrite for
  tampering detection.
  """

  @type t :: %__MODULE__{
          repo: atom(),
          repo_path: Path.t(),
          target_app: atom(),
          mix_exs_path: Path.t(),
          mix_exs_before_hash: String.t(),
          mix_exs_after_hash: String.t(),
          preimage: String.t(),
          replacement: String.t(),
          operation: :link_on
        }

  defstruct [
    :repo,
    :repo_path,
    :target_app,
    :mix_exs_path,
    :mix_exs_before_hash,
    :mix_exs_after_hash,
    :preimage,
    :replacement,
    :operation
  ]
end
