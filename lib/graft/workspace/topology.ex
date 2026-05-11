defmodule Graft.Workspace.Topology do
  @moduledoc """
  Dependency graph analysis for a workspace snapshot.

  Computes closures, cycles, topological ordering, and reverse-dependency
  indices from a snapshot's `deps` list.

  Pure: no filesystem or network access.
  """

  alias Graft.Workspace

  @type t :: %__MODULE__{
          # app_atom → [consumer_repo_atom]
          consumers: %{atom() => [atom()]},

          # repo_atom → [app_atom it provides as a dep to others]
          providers: %{atom() => [atom()]},

          # repo_atom → [repo_atom that depends on it, transitively]
          transitive_dependents: %{atom() => MapSet.t(atom())},

          # Sorted list for dependency-ordered operations
          topological_order: [atom()],

          # [app_atom] — apps that appear in deps but have no declared repo
          external_apps: [atom()],

          # true iff the sibling dependency graph contains a cycle
          cyclic?: boolean()
        }

  defstruct [
    :consumers,
    :providers,
    :transitive_dependents,
    :topological_order,
    :external_apps,
    :cyclic?
  ]

  @doc """
  Build a topology from a workspace snapshot's dependency list.
  """
  @spec from_workspace(Workspace.t()) :: t()
  def from_workspace(%Workspace{deps: deps, repos: repos}) do
    sibling_names = MapSet.new(repos, & &1.name)

    consumers =
      deps
      |> Enum.group_by(& &1.app, & &1.repo)
      |> Map.new(fn {app, repo_list} -> {app, Enum.uniq(repo_list)} end)

    providers =
      deps
      |> Enum.group_by(& &1.repo, & &1.app)
      |> Map.new(fn {repo, app_list} -> {repo, Enum.uniq(app_list)} end)

    external_apps =
      deps
      |> Enum.map(& &1.app)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(sibling_names, &1))

    {topo_order, cyclic?} = topological_sort(consumers, sibling_names)

    transitive = compute_transitive_dependents(consumers, sibling_names)

    %__MODULE__{
      consumers: consumers,
      providers: providers,
      transitive_dependents: transitive,
      topological_order: topo_order,
      external_apps: external_apps,
      cyclic?: cyclic?
    }
  end

  @doc """
  Return the transitive closure of repos affected by linking `target_apps`.

  Same semantics as `Graft.Link.Plan.closure/2` but operating on the
  pre-computed topology.
  """
  @spec link_closure(t(), [atom()]) :: [{atom(), atom()}]
  def link_closure(%__MODULE__{consumers: consumers} = topology, target_apps) do
    do_app_closure(target_apps, consumers, MapSet.new(), [])
    |> Enum.reject(fn {_, app} -> app in topology.external_apps end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  ## ─── Closure ────────────────────────────────────────────────────────

  defp do_app_closure([], _consumers, _visited, acc), do: acc

  defp do_app_closure([app | rest], consumers, visited, acc) do
    if MapSet.member?(visited, app) do
      do_app_closure(rest, consumers, visited, acc)
    else
      visited = MapSet.put(visited, app)

      new_pairs =
        Map.get(consumers, app, [])
        |> Enum.flat_map(&[{&1, app}])
        |> Enum.reject(&(&1 in acc))

      # The repos that consume `app` become new apps to explore,
      # because we want to find who consumes those repos (as apps).
      new_apps = Enum.map(new_pairs, &elem(&1, 0))

      do_app_closure(rest ++ new_apps, consumers, visited, acc ++ new_pairs)
    end
  end

  ## ─── Topological sort ─────────────────────────────────────────────

  defp topological_sort(consumers, sibling_names) do
    # Kahn's algorithm on repo→repo edges derived from deps
    graph = build_repo_graph(consumers, sibling_names)
    in_degree = compute_in_degrees(graph)

    queue =
      sibling_names
      |> MapSet.to_list()
      |> Enum.filter(&(Map.get(in_degree, &1, 0) == 0))
      |> Enum.sort()

    {order, final_in_degree} = kahn(queue, graph, in_degree, [])

    cyclic? = Enum.any?(final_in_degree, fn {_repo, deg} -> deg > 0 end)
    {Enum.reverse(order), cyclic?}
  end

  defp build_repo_graph(consumers, sibling_names) do
    # repo_a → [repo_b] means repo_a depends on repo_b
    sibling_names
    |> MapSet.to_list()
    |> Enum.reduce(%{}, fn repo, acc ->
      deps_of_repo = Map.get(consumers, repo, [])
      internal_deps = Enum.filter(deps_of_repo, &MapSet.member?(sibling_names, &1))
      Map.put(acc, repo, Enum.uniq(internal_deps))
    end)
  end

  defp compute_in_degrees(graph) do
    graph
    |> Enum.flat_map(fn {_repo, deps} -> deps end)
    |> Enum.frequencies()
    |> then(fn freqs ->
      # Ensure every repo has an entry (0 if no incoming edges)
      Map.keys(graph)
      |> Enum.reduce(freqs, &Map.put_new(&2, &1, 0))
    end)
  end

  defp kahn([], _graph, in_degree, order), do: {order, in_degree}

  defp kahn([repo | rest], graph, in_degree, order) do
    dependents = Map.get(graph, repo, [])

    {new_queue, new_degree} =
      Enum.reduce(dependents, {rest, in_degree}, fn dep, {queue, degree} ->
        new_deg = Map.update!(degree, dep, &(&1 - 1))

        if new_deg[dep] == 0 do
          {insert_sorted(queue, dep), new_deg}
        else
          {queue, new_deg}
        end
      end)

    kahn(new_queue, graph, new_degree, [repo | order])
  end

  defp insert_sorted(list, item) do
    {before, rest} = Enum.split_while(list, &(&1 < item))
    before ++ [item | rest]
  end

  ## ─── Transitive dependents ──────────────────────────────────────────

  defp compute_transitive_dependents(consumers, sibling_names) do
    sibling_names
    |> MapSet.to_list()
    |> Enum.reduce(%{}, fn repo, acc ->
      dependents = all_dependents(repo, consumers, sibling_names)
      Map.put(acc, repo, dependents)
    end)
  end

  defp all_dependents(repo, consumers, sibling_names) do
    # BFS from repo outward: who directly or transitively depends on it?
    do_bfs([repo], consumers, sibling_names, MapSet.new())
    |> MapSet.delete(repo)
  end

  defp do_bfs([], _consumers, _sibling_names, visited), do: visited

  defp do_bfs([current | rest], consumers, sibling_names, visited) do
    if MapSet.member?(visited, current) do
      do_bfs(rest, consumers, sibling_names, visited)
    else
      visited = MapSet.put(visited, current)

      # Who depends on `current`?
      dependents =
        consumers
        |> Enum.flat_map(fn {app, repos} ->
          if app == current do
            repos
          else
            []
          end
        end)
        |> Enum.filter(&MapSet.member?(sibling_names, &1))
        |> Enum.reject(&MapSet.member?(visited, &1))

      do_bfs(rest ++ dependents, consumers, sibling_names, visited)
    end
  end
end
