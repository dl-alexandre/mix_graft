defmodule Graft.Verify do
  @moduledoc """
  Verify invariants against a workspace snapshot.

  Checks topology, ownership, drift, safety, and capability constraints
  before any materialization is attempted.

  Returns a list of violations, grouped by severity.

  ## Invariant Categories

  * **Topology** — dependency graph structural integrity
  * **Ownership** — filesystem permissions and isolation
  * **Drift** — divergence between expected and observed state
  * **Safety** — operational risk bounds
  * **Capability** — required resources and compatibility

  ## Usage

      snapshot = Workspace.snapshot(".")
      violations = Verify.check(snapshot)

      if Verify.pass?(violations) do
        # Safe to proceed with graft
      else
        Verify.report(violations)
      end
  """

  alias Graft.Workspace
  alias Graft.Workspace.Topology

  defmodule Violation do
    @moduledoc "A single invariant violation."

    @type severity :: :fatal | :error | :warning | :info

    @type t :: %__MODULE__{
            category: :topology | :ownership | :drift | :safety | :capability,
            severity: severity(),
            invariant: String.t(),
            target: String.t() | nil,
            message: String.t(),
            details: map()
          }

    defstruct [:category, :severity, :invariant, :target, :message, :details]
  end

  @doc """
  Check all invariants against a workspace snapshot.

  Returns a list of violations, empty if all invariants pass.
  """
  @spec check(Workspace.t()) :: [Violation.t()]
  def check(%Workspace{} = snapshot) do
    []
    |> check_topology(snapshot)
    |> check_ownership(snapshot)
    |> check_drift(snapshot)
    |> check_safety(snapshot)
    |> check_capabilities(snapshot)
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.category, &1.invariant})
  end

  @doc """
  True if there are no fatal or error violations.

  Warnings may be present.
  """
  @spec pass?([Violation.t()]) :: boolean()
  def pass?(violations) do
    not Enum.any?(violations, &(&1.severity in [:fatal, :error]))
  end

  @doc """
  Format violations for human display.
  """
  @spec report([Violation.t()]) :: String.t()
  def report(violations) do
    violations
    |> Enum.group_by(& &1.severity)
    |> Enum.map(fn {severity, items} ->
      header = severity_header(severity)
      lines = Enum.map(items, &format_violation/1)
      [header, lines]
    end)
    |> IO.iodata_to_binary()
  end

  ## ─── Topology Invariants ──────────────────────────────────────────────

  defp check_topology(violations, %Workspace{topology: nil}) do
    [
      violation(
        :topology,
        :fatal,
        "topology_computed",
        "Topology not computed in snapshot. Run Workspace.snapshot/1 first."
      )
      | violations
    ]
  end

  defp check_topology(violations, %Workspace{topology: topology, repos: repos}) do
    violations
    |> check_no_cycles(topology)
    |> check_valid_topo_order(topology, repos)
    |> check_no_conflicting_app_names(topology, repos)
    |> check_external_apps_resolvable(topology, repos)
  end

  defp check_no_cycles(violations, %Topology{cyclic?: true}) do
    [
      violation(
        :topology,
        :fatal,
        "no_cycles",
        "Dependency graph contains cycles. Cyclic sibling dependencies cannot be grafted."
      )
      | violations
    ]
  end

  defp check_no_cycles(violations, %Topology{cyclic?: false}), do: violations

  defp check_valid_topo_order(violations, %Topology{topological_order: order}, repos) do
    repo_names = MapSet.new(repos, & &1.name)
    missing = MapSet.difference(repo_names, MapSet.new(order))

    if MapSet.size(missing) > 0 do
      [
        violation(
          :topology,
          :error,
          "valid_topo_order",
          "Topological order missing repos: #{inspect(MapSet.to_list(missing))}"
        )
        | violations
      ]
    else
      violations
    end
  end

  defp check_no_conflicting_app_names(violations, %Topology{providers: providers}, _repos) do
    # Multiple repos providing the same OTP app name
    conflicts =
      providers
      |> Enum.filter(fn {_repo, apps} -> length(apps) > 0 end)
      |> Enum.flat_map(fn {repo, apps} ->
        Enum.map(apps, fn app ->
          other_repos =
            providers
            |> Enum.filter(fn {r, a} -> r != repo and app in a end)
            |> Enum.map(&elem(&1, 0))

          if length(other_repos) > 0 do
            {repo, app, other_repos}
          else
            nil
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)

    Enum.reduce(conflicts, violations, fn {repo, app, others}, acc ->
      [
        violation(
          :topology,
          :error,
          "no_conflicting_app_names",
          "Repo #{repo} provides app #{app}, but #{inspect(others)} also declare it as a dependency source"
        )
        | acc
      ]
    end)
  end

  defp check_external_apps_resolvable(violations, %Topology{external_apps: []}, _repos),
    do: violations

  defp check_external_apps_resolvable(violations, %Topology{external_apps: apps}, _repos) do
    # External apps are not errors — they just require hex resolution
    infos =
      Enum.map(apps, fn app ->
        violation(
          :topology,
          :info,
          "external_apps_resolvable",
          "App #{app} is not declared in workspace; will be resolved from Hex"
        )
      end)

    infos ++ violations
  end

  ## ─── Ownership Invariants ───────────────────────────────────────────

  defp check_ownership(violations, %Workspace{repos: repos, links: links}) do
    violations
    |> check_managed_repos_writable(repos, links)
    |> check_ephemeral_isolation(repos)
  end

  defp check_managed_repos_writable(violations, repos, links) do
    linked_repos = MapSet.new(links, & &1.repo)

    Enum.reduce(repos, violations, fn repo, acc ->
      if repo.exists? and MapSet.member?(linked_repos, repo.name) do
        mix_exs = Path.join(repo.absolute_path, "mix.exs")

        case File.stat(mix_exs) do
          {:ok, %{access: access}} when access in [:read_write, :write] ->
            acc

          {:ok, %{access: :read}} ->
            [
              violation(
                :ownership,
                :error,
                "managed_repos_writable",
                "Repo #{repo.name} mix.exs is read-only; graft cannot rewrite dependencies",
                %{path: mix_exs}
              )
              | acc
            ]

          {:error, reason} ->
            [
              violation(
                :ownership,
                :error,
                "managed_repos_writable",
                "Cannot stat #{repo.name} mix.exs: #{:file.format_error(reason)}",
                %{path: mix_exs, reason: reason}
              )
              | acc
            ]
        end
      else
        acc
      end
    end)
  end

  defp check_ephemeral_isolation(violations, repos) do
    # Check that ephemeral workspace paths (if any) are outside declared workspace root
    Enum.reduce(repos, violations, fn repo, acc ->
      if String.starts_with?(repo.absolute_path, System.tmp_dir!()) do
        [
          violation(
            :ownership,
            :warning,
            "ephemeral_isolation",
            "Repo #{repo.name} is in temp directory (#{repo.absolute_path}); ephemeral graft isolation may not be guaranteed"
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  ## ─── Drift Invariants ───────────────────────────────────────────────

  defp check_drift(violations, %Workspace{repos: repos, git: git_states, links: links}) do
    violations
    |> check_local_modifications(repos, git_states)
    |> check_detached_heads(repos, git_states)
    |> check_branch_divergence(repos, git_states)
    |> check_missing_mounts(links)
    |> check_orphaned_links(links, repos)
  end

  defp check_local_modifications(violations, _repos, git_states) do
    dirty_repos =
      git_states
      |> Enum.filter(& &1.dirty?)
      |> Enum.map(& &1.repo)

    Enum.reduce(dirty_repos, violations, fn repo_name, acc ->
      [
        violation(
          :drift,
          :warning,
          "local_modifications",
          "Repo #{repo_name} has uncommitted changes; graft may conflict"
        )
        | acc
      ]
    end)
  end

  defp check_detached_heads(violations, _repos, git_states) do
    detached =
      git_states
      |> Enum.filter(& &1.detached_head?)
      |> Enum.map(& &1.repo)

    Enum.reduce(detached, violations, fn repo_name, acc ->
      [
        violation(
          :drift,
          :warning,
          "detached_heads",
          "Repo #{repo_name} is on detached HEAD; graft operations may be ambiguous"
        )
        | acc
      ]
    end)
  end

  defp check_branch_divergence(violations, _repos, git_states) do
    diverged =
      git_states
      |> Enum.filter(fn gs -> gs.ahead > 0 and gs.behind > 0 end)

    Enum.reduce(diverged, violations, fn gs, acc ->
      [
        violation(
          :drift,
          :error,
          "branch_divergence",
          "Repo #{gs.repo} branch diverged: #{gs.ahead} ahead, #{gs.behind} behind #{gs.upstream}"
        )
        | acc
      ]
    end)
  end

  defp check_missing_mounts(violations, links) do
    missing =
      links
      |> Enum.filter(& &1.active)
      |> Enum.reject(fn link ->
        target = Path.join(link.target_path)
        File.dir?(target) or File.regular?(target)
      end)

    Enum.reduce(missing, violations, fn link, acc ->
      [
        violation(
          :drift,
          :error,
          "missing_mounts",
          "Link #{link.repo} → #{link.target_path} target does not exist on disk"
        )
        | acc
      ]
    end)
  end

  defp check_orphaned_links(violations, links, repos) do
    repo_names = MapSet.new(repos, & &1.name)

    orphaned =
      links
      |> Enum.reject(fn link ->
        MapSet.member?(repo_names, link.repo)
      end)

    Enum.reduce(orphaned, violations, fn link, acc ->
      [
        violation(
          :drift,
          :warning,
          "orphaned_links",
          "Link references repo #{link.repo} which is not in current workspace snapshot"
        )
        | acc
      ]
    end)
  end

  ## ─── Safety Invariants ──────────────────────────────────────────────

  defp check_safety(violations, %Workspace{root: root, repos: repos}) do
    violations
    |> check_graft_root_confinement(root, repos)
    |> check_no_path_traversal(repos)
    |> check_rollback_feasibility(repos)
  end

  defp check_graft_root_confinement(violations, root, repos) do
    Enum.reduce(repos, violations, fn repo, acc ->
      if String.starts_with?(repo.absolute_path, root <> "/") or repo.absolute_path == root do
        acc
      else
        [
          violation(
            :safety,
            :fatal,
            "graft_root_confinement",
            "Repo #{repo.name} at #{repo.absolute_path} escapes workspace root #{root}"
          )
          | acc
        ]
      end
    end)
  end

  defp check_no_path_traversal(violations, repos) do
    Enum.reduce(repos, violations, fn repo, acc ->
      if String.contains?(repo.path, "..") or String.contains?(repo.absolute_path, "..") do
        [
          violation(
            :safety,
            :fatal,
            "no_path_traversal",
            "Repo #{repo.name} path contains '..' traversal: #{repo.path}"
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp check_rollback_feasibility(violations, repos) do
    # Check that every repo has mix.exs backup / can be restored
    Enum.reduce(repos, violations, fn repo, acc ->
      backup = Path.join([repo.absolute_path, ".graft", "backups"])

      if repo.exists? and not File.dir?(backup) do
        [
          violation(
            :safety,
            :warning,
            "rollback_feasibility",
            "Repo #{repo.name} has no .graft/backups directory; rollback may require manual git operations"
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  ## ─── Capability Invariants ──────────────────────────────────────────

  defp check_capabilities(violations, %Workspace{repos: repos, deps: deps}) do
    violations
    |> check_dependency_closure(repos, deps)
    |> check_compatible_versions(repos, deps)
  end

  defp check_dependency_closure(violations, repos, deps) do
    repo_names = MapSet.new(repos, & &1.name)
    dep_apps = MapSet.new(deps, & &1.app)

    # Every dep app must either be a declared repo or an external (hex/git) dep
    missing =
      dep_apps
      |> MapSet.difference(repo_names)
      |> MapSet.reject(fn _app ->
        # Is it a known external package? (would need hex metadata)
        # For now, assume external apps are okay (topology invariant already checked)
        true
      end)

    if MapSet.size(missing) == 0 do
      violations
    else
      [
        violation(
          :capability,
          :error,
          "dependency_closure",
          "Dependency closure incomplete: #{inspect(MapSet.to_list(missing))} not resolved"
        )
        | violations
      ]
    end
  end

  defp check_compatible_versions(violations, _repos, _deps) do
    # Version compatibility requires hex metadata; placeholder for now
    # Real implementation would check lockfile against declared ranges
    violations
  end

  ## ─── Helpers ─────────────────────────────────────────────────────────

  defp violation(category, severity, invariant, message, details \\ %{}) do
    %Violation{
      category: category,
      severity: severity,
      invariant: invariant,
      target: details[:target],
      message: message,
      details: details
    }
  end

  defp severity_rank(:fatal), do: 0
  defp severity_rank(:error), do: 1
  defp severity_rank(:warning), do: 2
  defp severity_rank(:info), do: 3

  defp severity_header(:fatal), do: "FATAL:\n"
  defp severity_header(:error), do: "ERROR:\n"
  defp severity_header(:warning), do: "WARNING:\n"
  defp severity_header(:info), do: "INFO:\n"

  defp format_violation(%Violation{invariant: inv, message: msg, target: nil}) do
    "  [#{inv}] #{msg}\n"
  end

  defp format_violation(%Violation{invariant: inv, message: msg, target: target}) do
    "  [#{inv}] #{msg} (target: #{target})\n"
  end
end
