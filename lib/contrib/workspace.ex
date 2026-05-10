defmodule Contrib.Workspace do
  @moduledoc """
  Canonical workspace snapshot. Every command derives from this struct.

  ## Invariants

  * Snapshot construction is side-effect free. No writes occur during
    `snapshot/1`.
  * Only local state is gathered by default. Network-enriched domains
    (Hex, GitHub) are opt-in via `with_hex_data/1`, `with_github_data/1`.
  """

  alias Contrib.Workspace.{Repo, Dependency, Link, GitState, PullRequest, HealthIssue}

  @type t :: %__MODULE__{
          root: Path.t(),
          generated_at: DateTime.t(),
          repos: [Repo.t()],
          deps: [Dependency.t()],
          links: [Link.t()],
          git: [GitState.t()],
          prs: [PullRequest.t()],
          health: [HealthIssue.t()]
        }

  defstruct [:root, :generated_at, repos: [], deps: [], links: [], git: [], prs: [], health: []]

  @doc """
  Build a snapshot of the workspace rooted at `root`.

  Side-effect free. Reads `contrib.exs`, sibling `mix.exs` files,
  `.contrib/state.json`, and local `git` plumbing.
  """
  @spec snapshot(Path.t()) :: {:ok, t()} | {:error, term()}
  def snapshot(_root \\ File.cwd!()) do
    {:error, :not_implemented}
  end

  @doc "Layer Hex API data (latest versions, retirements) onto an existing snapshot."
  @spec with_hex_data(t()) :: {:ok, t()} | {:error, term()}
  def with_hex_data(_snapshot), do: {:error, :not_implemented}

  @doc "Layer GitHub API data (open PRs, CI status) onto an existing snapshot."
  @spec with_github_data(t()) :: {:ok, t()} | {:error, term()}
  def with_github_data(_snapshot), do: {:error, :not_implemented}
end
