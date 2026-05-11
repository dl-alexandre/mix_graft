defmodule Graft.Workspace do
  @moduledoc """
  Canonical workspace snapshot. Every command derives from this struct.

  ## Invariants

    * Snapshot construction is side-effect free. No filesystem mutations,
      no shell-outs to `git` or `mix`, no network calls.
    * Only local state is gathered by default. Network-enriched domains
      (Hex, GitHub, CI) are opt-in via `with_hex_data/1` and
      `with_github_data/1`.

  v0.1 populates `:repos` and `:deps`. Git, PR, and health derivation
  arrive in M2.
  """

  alias Graft.{Error, GitState, Manifest}
  alias Graft.Validate.ResultFile, as: ValidateResultFile
  alias Graft.Validate.ResultFile.Persisted, as: ValidateResultPersisted
  alias Graft.Workspace.{Repo, Dependency, Link, PullRequest, HealthIssue, Topology}
  alias Graft.Workspace.DepsParser

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          root: Path.t(),
          generated_at: DateTime.t(),
          repos: [Repo.t()],
          deps: [Dependency.t()],
          links: [Link.t()],
          topology: Topology.t() | nil,
          git: [GitState.t()],
          prs: [PullRequest.t()],
          health: [HealthIssue.t()],
          diagnostics: [Diagnostic.t()],
          validate_result: ValidateResultPersisted.t() | nil,
          github: map() | nil,
          hex: map() | nil
        }

  defstruct [
    :id,
    :root,
    :generated_at,
    schema_version: 1,
    repos: [],
    deps: [],
    links: [],
    topology: nil,
    git: [],
    prs: [],
    health: [],
    diagnostics: [],
    validate_result: nil,
    github: nil,
    hex: nil
  ]

  @doc """
  Build a snapshot of the workspace rooted at `dir`.

  Reads `graft.exs`, materializes each declared sibling against the
  filesystem, and parses each present `mix.exs` for dependency tuples.
  """
  @spec snapshot(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def snapshot(dir \\ File.cwd!()) when is_binary(dir) do
    with {:ok, manifest} <- Manifest.load(dir) do
      repos =
        manifest.siblings
        |> Enum.map(&materialize_repo/1)
        |> Enum.sort_by(&Atom.to_string(&1.name))

      deps =
        repos
        |> Enum.flat_map(&parse_deps/1)
        |> Enum.sort_by(fn d -> {Atom.to_string(d.repo), Atom.to_string(d.app)} end)

      git_states =
        repos
        |> Enum.filter(& &1.exists?)
        |> Enum.map(&GitState.read(&1.absolute_path, repo: &1.name))

      validate_result =
        case ValidateResultFile.load(manifest.root) do
          {:ok, persisted} -> persisted
          {:error, _} -> nil
        end

      topology =
        Topology.from_workspace(%__MODULE__{root: manifest.root, repos: repos, deps: deps})

      {:ok,
       %__MODULE__{
         id: generate_uuid(),
         schema_version: 1,
         root: manifest.root,
         generated_at: DateTime.utc_now(),
         repos: repos,
         deps: deps,
         topology: topology,
         git: git_states,
         validate_result: validate_result
       }}
    end
  end

  @doc "Layer Hex API data (latest versions, retirements) onto an existing snapshot."
  @spec with_hex_data(t()) :: {:ok, t()} | {:error, Error.t()}
  def with_hex_data(_snapshot) do
    {:error, Error.new(:not_implemented, "Workspace.with_hex_data/1 is not implemented yet")}
  end

  @doc "Layer GitHub API data (open PRs, CI status) onto an existing snapshot."
  @spec with_github_data(t()) :: {:ok, t()} | {:error, Error.t()}
  def with_github_data(_snapshot) do
    {:error, Error.new(:not_implemented, "Workspace.with_github_data/1 is not implemented yet")}
  end

  ## ─── Private ────────────────────────────────────────────────────────

  defp materialize_repo(%Manifest.Sibling{} = s) do
    abs = s.absolute_path
    exists? = File.dir?(abs)
    has_mix_exs? = exists? and File.regular?(Path.join(abs, "mix.exs"))

    %Repo{
      name: s.name,
      path: s.path,
      absolute_path: abs,
      exists?: exists?,
      has_mix_exs?: has_mix_exs?
    }
  end

  defp parse_deps(%Repo{has_mix_exs?: false}), do: []

  defp parse_deps(%Repo{absolute_path: abs, name: name}) do
    mix_exs = Path.join(abs, "mix.exs")

    case File.read(mix_exs) do
      {:ok, source} -> DepsParser.parse(source, name)
      {:error, _} -> []
    end
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.replace(~r/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "\\1-\\2-\\3-\\4-\\5")
  end
end
