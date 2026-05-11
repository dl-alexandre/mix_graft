defmodule Graft.Validate.Plan do
  @moduledoc """
  Plans a `validate` operation across a Graft workspace. Pure: reads
  the workspace snapshot only; no shell-outs, no filesystem mutation.

  ## Closure

  The closure of validating `targets` is the targets *and* every
  workspace sibling that transitively depends on them — the same shape
  link.on uses, because changing `req_llm` requires verifying its
  consumers still build and pass.

  ## Execution order

  Topological by workspace dep direction: a sibling's dependencies
  validate before the sibling itself. Within a topological layer,
  alphabetic for determinism.

  Cycles in the sibling dep graph (rare but legal) are reported as a
  plan warning; remaining nodes are appended alphabetically rather than
  failing the plan.

  ## Command sequence (v0.1)

  Per repo, in fixed order:

    1. `mix deps.get`
    2. `mix compile --warnings-as-errors`
    3. `mix test`

  v0.1 is hardcoded. A future milestone will read an optional
  `:validate` key from `graft.exs` for project-configured commands.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.Repo
  alias Graft.Validate.Plan.{Command, Step}

  @type t :: %__MODULE__{
          operation: :validate,
          generated_at: DateTime.t(),
          workspace_root: Path.t(),
          target_apps: [atom()],
          affected_repos: [atom()],
          steps: [Step.t()],
          warnings: [String.t()]
        }

  defstruct operation: :validate,
            generated_at: nil,
            workspace_root: nil,
            target_apps: [],
            affected_repos: [],
            steps: [],
            warnings: []

  @default_commands [
    %Command{kind: :deps_get, argv: ["deps.get"], description: "mix deps.get"},
    %Command{
      kind: :compile,
      argv: ["compile", "--warnings-as-errors"],
      description: "mix compile --warnings-as-errors"
    },
    %Command{kind: :test, argv: ["test"], description: "mix test"}
  ]

  @doc "Default per-repo command sequence (used unless overridden later)."
  def default_commands, do: @default_commands

  @spec build(Workspace.t(), [atom()]) :: {:ok, t()} | {:error, Error.t()}
  def build(%Workspace{} = workspace, target_apps) when is_list(target_apps) do
    targets = target_apps |> Enum.uniq() |> Enum.sort_by(&Atom.to_string/1)

    with :ok <- validate_nonempty(targets),
         :ok <- validate_targets_in_workspace(targets, workspace) do
      {closure, warnings} = compute_closure_and_order(workspace, targets)

      steps =
        closure
        |> Enum.map(&build_step(&1, workspace))
        |> Enum.reject(&is_nil/1)

      {:ok,
       %__MODULE__{
         operation: :validate,
         generated_at: DateTime.utc_now(),
         workspace_root: workspace.root,
         target_apps: targets,
         affected_repos: Enum.map(steps, & &1.repo),
         steps: steps,
         warnings: warnings
       }}
    end
  end

  ## ─── Validation ─────────────────────────────────────────────────────

  defp validate_nonempty([]),
    do: {:error, Error.new(:plan_invalid_operation, "Target apps list must not be empty")}

  defp validate_nonempty(_), do: :ok

  defp validate_targets_in_workspace(targets, workspace) do
    sibling_names = MapSet.new(workspace.repos, & &1.name)

    case Enum.reject(targets, &MapSet.member?(sibling_names, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(
           :validate_target_not_in_workspace,
           "Target app(s) not declared as siblings in graft.exs: #{inspect(missing)}",
           %{targets: missing}
         )}
    end
  end

  ## ─── Closure + topological order ───────────────────────────────────

  defp compute_closure_and_order(workspace, targets) do
    sibling_set = MapSet.new(workspace.repos, & &1.name)

    consumers_of =
      workspace.deps
      |> Enum.filter(
        &(MapSet.member?(sibling_set, &1.app) and MapSet.member?(sibling_set, &1.repo))
      )
      |> Enum.group_by(& &1.app, & &1.repo)
      |> Map.new(fn {app, consumers} -> {app, Enum.uniq(consumers)} end)

    closure = walk_consumers(consumers_of, MapSet.new(targets), MapSet.new(targets))
    topological_order(MapSet.to_list(closure), workspace.deps, sibling_set)
  end

  defp walk_consumers(consumers_of, frontier, visited) do
    next =
      frontier
      |> Enum.flat_map(fn app -> Map.get(consumers_of, app, []) end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visited, &1))

    case next do
      [] -> visited
      _ -> walk_consumers(consumers_of, MapSet.new(next), MapSet.union(visited, MapSet.new(next)))
    end
  end

  # Kahn's algorithm with alphabetic tie-break. Cycles produce a warning
  # and the cyclic remainder is appended alphabetically.
  defp topological_order(nodes, deps, sibling_set) do
    closure_set = MapSet.new(nodes)

    edges =
      deps
      |> Enum.filter(
        &(MapSet.member?(closure_set, &1.app) and MapSet.member?(closure_set, &1.repo))
      )
      |> Enum.uniq_by(&{&1.app, &1.repo})

    adj =
      edges
      |> Enum.group_by(& &1.app, & &1.repo)
      |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)

    in_degree =
      edges
      |> Enum.group_by(& &1.repo, & &1.app)
      |> Map.new(fn {k, vs} -> {k, length(Enum.uniq(vs))} end)

    in_degree = Map.merge(Map.new(nodes, &{&1, 0}), in_degree)

    {order, leftover} = kahn([], in_degree, adj, MapSet.new(nodes))

    case leftover do
      [] ->
        _ = sibling_set
        {order, []}

      remaining ->
        sorted = Enum.sort_by(remaining, &Atom.to_string/1)

        {order ++ sorted,
         [
           "Cycle detected in workspace dep graph; remaining repos ordered alphabetically: #{inspect(sorted)}"
         ]}
    end
  end

  defp kahn(order, in_degree, adj, remaining) do
    ready =
      remaining
      |> MapSet.to_list()
      |> Enum.filter(&(Map.get(in_degree, &1) == 0))
      |> Enum.sort_by(&Atom.to_string/1)

    case ready do
      [] ->
        {order, MapSet.to_list(remaining)}

      [pick | _] ->
        new_in_degree =
          Map.get(adj, pick, [])
          |> Enum.reduce(in_degree, fn cons, acc -> Map.update!(acc, cons, &(&1 - 1)) end)

        kahn(order ++ [pick], new_in_degree, adj, MapSet.delete(remaining, pick))
    end
  end

  ## ─── Step construction ─────────────────────────────────────────────

  defp build_step(repo_name, workspace) do
    case Enum.find(workspace.repos, &(&1.name == repo_name)) do
      nil ->
        nil

      %Repo{} = repo ->
        %Step{
          repo: repo.name,
          repo_path: repo.absolute_path,
          commands: @default_commands
        }
    end
  end
end
