defmodule Contrib.Workspace.Repo do
  @moduledoc "A sibling repo declared in `contrib.exs`."

  @type t :: %__MODULE__{
          name: atom(),
          path: Path.t(),
          present?: boolean()
        }

  defstruct [:name, :path, present?: false]
end

defmodule Contrib.Workspace.Dependency do
  @moduledoc "A parsed dependency from a sibling's `mix.exs`."

  @type source :: :hex | :path | :git | :other

  @type t :: %__MODULE__{
          repo: atom(),
          name: atom(),
          source: source(),
          version: String.t() | nil,
          path: Path.t() | nil,
          opts: keyword()
        }

  defstruct [:repo, :name, :source, :version, :path, opts: []]
end

defmodule Contrib.Workspace.Link do
  @moduledoc "An active path-link recorded in `.contrib/state.json`."

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

defmodule Contrib.Workspace.GitState do
  @moduledoc "Local git state for a sibling repo."

  @type t :: %__MODULE__{
          repo: atom(),
          branch: String.t() | nil,
          dirty?: boolean(),
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          detached?: boolean()
        }

  defstruct [:repo, :branch, dirty?: false, ahead: 0, behind: 0, detached?: false]
end

defmodule Contrib.Workspace.PullRequest do
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

defmodule Contrib.Workspace.HealthIssue do
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
