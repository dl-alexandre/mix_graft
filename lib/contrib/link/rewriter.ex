defmodule Contrib.Link.Rewriter do
  @moduledoc """
  Sourceror-based AST rewriting of `mix.exs` deps blocks.

  Swaps `{:pkg, "~> x.y"}` to `{:pkg, path: "..."}` while preserving
  comments, formatting, and surrounding keyword opts (`only:`, `optional:`,
  etc.). Approach proven in spike against real-world `mix.exs` files.
  """

  @type rewrite_result :: %{
          source_before: String.t(),
          source_after: String.t(),
          preimage: String.t(),
          replacement: String.t()
        }

  @doc """
  Rewrite `source` so the dep `pkg` uses `path: relative_path`.
  Returns `:no_change` if the dep is not present or already a path dep.
  """
  @spec rewrite(String.t(), atom(), Path.t()) ::
          {:ok, rewrite_result()} | :no_change | {:error, term()}
  def rewrite(_source, _pkg, _relative_path), do: {:error, :not_implemented}
end
