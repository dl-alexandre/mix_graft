defmodule Graft.Workspace.Repo do
  @moduledoc "A sibling repo declared in `graft.exs`, materialized against the filesystem."

  @type ownership :: :external | :managed

  @type t :: %__MODULE__{
          name: atom(),
          path: Path.t(),
          absolute_path: Path.t(),
          exists?: boolean(),
          has_mix_exs?: boolean(),
          origin: String.t() | nil,
          ownership: ownership()
        }

  defstruct [
    :name,
    :path,
    :absolute_path,
    exists?: false,
    has_mix_exs?: false,
    origin: nil,
    ownership: :external
  ]
end

defmodule Graft.Workspace.Dependency do
  @moduledoc """
  A dependency declared in a sibling's `mix.exs`.

  `:source` classifies the dep:

    * `:hex`     — a versioned hex dep (`{:foo, "~> 1.0"}` etc.)
    * `:path`    — a local path dep (`{:foo, path: "../foo"}`)
    * `:git`     — a git dep (`{:foo, git: "..."}` or `github: "..."`)
    * `:unknown` — a tuple we recognised as a dep entry but cannot classify

  `:raw` is a canonical source-form rendering of the dep tuple, suitable for
  display and for recording in `.graft/state.json`.
  """

  @type source :: :hex | :path | :git | :unknown

  @type t :: %__MODULE__{
          repo: atom(),
          app: atom(),
          raw: String.t(),
          source: source()
        }

  defstruct [:repo, :app, :raw, :source]
end

defmodule Graft.Workspace.Link do
  @moduledoc "An active path-link recorded in `.graft/state.json`."

  @type t :: %__MODULE__{
          repo: atom(),
          dep: atom(),
          mix_exs_sha256_before: String.t(),
          mix_exs_sha256_after: String.t(),
          preimage: String.t(),
          replacement: String.t()
        }

  defstruct [:repo, :dep, :mix_exs_sha256_before, :mix_exs_sha256_after, :preimage, :replacement]
end

defmodule Graft.Workspace.PullRequest do
  @moduledoc "An open PR (populated only via `Workspace.with_github_data/1`)."

  @type t :: %__MODULE__{
          repo: atom(),
          number: pos_integer(),
          title: String.t(),
          state: :open | :draft | :merged | :closed,
          url: String.t()
        }

  defstruct [:repo, :number, :title, :state, :url]
end

defmodule Graft.Workspace.HealthIssue do
  @moduledoc "A derived health concern surfaced by `doctor`."

  @type severity :: :info | :warn | :error

  @type t :: %__MODULE__{
          severity: severity(),
          repo: atom() | nil,
          kind: atom(),
          message: String.t()
        }

  defstruct [:severity, :repo, :kind, :message]
end
