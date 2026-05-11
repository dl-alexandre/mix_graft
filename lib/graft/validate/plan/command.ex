defmodule Graft.Validate.Plan.Command do
  @moduledoc """
  One mix invocation in a validate plan. v0.1 ships three command
  kinds: `:deps_get`, `:compile`, `:test`. Argv is the literal argument
  list passed to `mix`; description is the human-readable form.
  """

  @type kind :: :deps_get | :compile | :test

  @type t :: %__MODULE__{
          kind: kind(),
          argv: [String.t()],
          description: String.t()
        }

  defstruct [:kind, :argv, :description]
end
