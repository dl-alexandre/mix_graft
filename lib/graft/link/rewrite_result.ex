defmodule Graft.Link.RewriteResult do
  @moduledoc """
  Result of a single `Graft.Link.Rewriter.rewrite/3` invocation.

  * `original_contents` / `rewritten_contents` — the full file source
    before and after the rewrite. When the dep is absent or the rewrite
    is a no-op, both are equal.
  * `changed?` — whether the file source actually changed.
  * `matched_dep?` — whether a dep tuple matching the target app was
    found in the deps function body.
  * `original_dep_ast` / `rewritten_dep_ast` — the Sourceror AST of the
    matched dep tuple before and after rewriting. `nil` when the dep
    was absent.
  """

  @type t :: %__MODULE__{
          original_contents: String.t(),
          rewritten_contents: String.t(),
          changed?: boolean(),
          matched_dep?: boolean(),
          original_dep_ast: Macro.t() | nil,
          rewritten_dep_ast: Macro.t() | nil
        }

  defstruct [
    :original_contents,
    :rewritten_contents,
    :original_dep_ast,
    :rewritten_dep_ast,
    changed?: false,
    matched_dep?: false
  ]
end
