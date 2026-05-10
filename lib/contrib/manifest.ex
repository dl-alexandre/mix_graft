defmodule Contrib.Manifest do
  @moduledoc """
  Loads and validates `contrib.exs` — the workspace manifest.

  Format (eval'd as Elixir):

      %{
        root: ".",
        siblings: [
          %{name: :req_llm, path: "req_llm"},
          %{name: :jido,    path: "jido"}
        ]
      }
  """

  @type sibling :: %{name: atom(), path: Path.t()}
  @type t :: %{root: Path.t(), siblings: [sibling()]}

  @manifest_filename "contrib.exs"

  @doc "Load the manifest from `dir`. Returns `{:error, :not_found}` if missing."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(_dir \\ File.cwd!()) do
    {:error, :not_implemented}
  end

  @doc "The conventional manifest filename."
  def filename, do: @manifest_filename
end
