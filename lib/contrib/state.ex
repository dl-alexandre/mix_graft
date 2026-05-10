defmodule Contrib.State do
  @moduledoc """
  Reads and writes `.contrib/state.json` — the link state file.

  Records, for each rewritten dep, the SHA-256 of `mix.exs` before and
  after the rewrite, plus the literal preimage/replacement text. This
  is the source of truth for `link.off`. Hash equality is the boundary
  between "safe to revert" and "needs human attention."
  """

  alias Contrib.Workspace.Link

  @state_dir ".contrib"
  @state_file "state.json"
  @schema_version 1

  @type t :: %{
          version: pos_integer(),
          workspace_root: Path.t(),
          links: [Link.t()]
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(_root \\ File.cwd!()), do: {:error, :not_implemented}

  @spec save(Path.t(), t()) :: :ok | {:error, term()}
  def save(_root, _state), do: {:error, :not_implemented}

  @spec sha256(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256(_path), do: {:error, :not_implemented}

  def schema_version, do: @schema_version
  def state_dir, do: @state_dir
  def state_file, do: @state_file
end
