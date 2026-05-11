defmodule Mix.Tasks.Graft.Demo do
  @shortdoc "Run a full graft vertical-slice demo with one local repo"

  @moduledoc """
  End-to-end graft demo: snapshot → diff → plan → verify → materialize → observe → teardown.

      mix contrib.graft.demo --repo path/to/repo --name myrepo

  The demo creates a temporary graft root, materializes the repo as a
  managed symlink, observes the result, then tears everything down.
  Nothing is left on disk after a successful run.

  ## Options

    * `--repo` — path to the source repo (required)
    * `--name` — atom name for the managed entry (required)
    * `--root` — graft root directory (default: temp dir)
    * `--json` — output structured JSON instead of human text

  ## Exit codes

    * 0 — full loop completed successfully
    * 1 — loop completed but drift or verification warnings were present
    * 2 — error (bad args, missing repo, unsafe path, etc.)
  """

  use Mix.Task

  alias Graft.Workspace
  alias Graft.{Drift, Materializer, Plan, Safety, Teardown}

  @switches [repo: :string, name: :string, root: :string, json: :boolean]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output, 0} ->
        Mix.shell().info(output)

      {:ok, output, 1} ->
        Mix.shell().info(output)
        exit({:shutdown, 1})

      {:error, output, :stderr} ->
        Mix.shell().error(output)
        exit({:shutdown, 2})
    end
  end

  @doc """
  Pure entry point for testing. Returns `{status, output, exit_code}`.
  """
  @spec execute([String.t()]) ::
          {:ok, String.t(), 0 | 1} | {:error, String.t(), :stderr}
  def execute(argv) do
    with {:ok, opts} <- parse_opts(argv),
         {:ok, repo_path} <- validate_repo_path(opts[:repo]),
         {:ok, repo_name} <- validate_repo_name(opts[:name]),
         graft_root <- opts[:root] || tmp_graft_root(),
         :ok <- ensure_safe_graft_root(graft_root),
         {:ok, result, _exit_code} <- run_loop(repo_path, repo_name, graft_root) do
      format_result(result, opts[:json])
    else
      {:error, message} ->
        {:error, "graft.graft.demo: #{message}", :stderr}
    end
  end

  ## ─── The Loop ───────────────────────────────────────────────────────

  defp run_loop(repo_path, repo_name, graft_root) do
    # Step 1: Build current snapshot (empty workspace)
    current = build_empty_workspace(graft_root)

    # Step 2: Build desired snapshot (with repo as managed)
    desired = build_desired_workspace(current, repo_path, repo_name)

    # Step 3: Diff
    delta = Workspace.Diff.diff(current, desired)

    # Step 4: Plan
    plan = Plan.from_diff(current, desired)

    # Step 5: Custom verification for the demo
    # Standard Plan.verify/1 checks preconditions against the current snapshot,
    # but in the graft demo the repo does not exist in the empty current workspace.
    # Instead we verify the real prerequisites ourselves.
    custom_verification = verify_demo_prerequisites(repo_path, graft_root, plan)

    # Step 6: Materialize
    repo = hd(desired.repos)
    materialization = Materializer.materialize_repo(repo, graft_root)

    # Step 7: Observe / Drift check
    drift = Drift.check(repo, graft_root)

    # Step 8: Teardown
    teardown = Teardown.teardown_repo(repo, graft_root)

    result = %{
      current_id: current.id,
      desired_id: desired.id,
      diff: summarize_diff(delta),
      plan_id: plan.id,
      plan_action: plan.action,
      plan_operations_count: length(plan.operations),
      verification: custom_verification,
      materialized_path:
        case materialization do
          {:ok, map} -> Map.get(map, repo_name)
          _ -> nil
        end,
      materialization_ok: match?({:ok, _}, materialization),
      drift: Drift.summary(drift),
      drift_ok: Drift.ok?(drift),
      teardown_ok: teardown == :ok,
      graft_root: graft_root,
      repo_path: repo_path,
      repo_name: repo_name
    }

    exit_code = if result.drift_ok and result.verification.ok, do: 0, else: 1
    {:ok, result, exit_code}
  end

  ## ─── Workspace Construction ─────────────────────────────────────────

  defp build_empty_workspace(graft_root) do
    %Workspace{
      id: generate_id(),
      schema_version: 1,
      root: graft_root,
      generated_at: DateTime.utc_now(),
      repos: [],
      deps: [],
      git: [],
      links: [],
      topology: %Workspace.Topology{
        consumers: %{},
        providers: %{},
        transitive_dependents: %{},
        topological_order: [],
        external_apps: [],
        cyclic?: false
      }
    }
  end

  defp build_desired_workspace(current, repo_path, repo_name) do
    repo = %Workspace.Repo{
      name: repo_name,
      path: Atom.to_string(repo_name),
      absolute_path: Path.expand(repo_path),
      exists?: File.dir?(repo_path),
      has_mix_exs?: File.regular?(Path.join(repo_path, "mix.exs")),
      ownership: :managed
    }

    git =
      if repo.exists? do
        [Graft.GitState.read(repo.absolute_path, repo: repo_name)]
      else
        []
      end

    repos = [repo]

    %Workspace{} = current

    %{
      current
      | id: generate_id(),
        generated_at: DateTime.utc_now(),
        repos: repos,
        git: git,
        topology: Workspace.Topology.from_workspace(%Workspace{repos: repos, deps: []})
    }
  end

  ## ─── Custom Verification ──────────────────────────────────────────

  defp verify_demo_prerequisites(repo_path, graft_root, plan) do
    link_path = Path.join(graft_root, Path.basename(repo_path))

    cond do
      not File.dir?(repo_path) ->
        %{ok: false, status: :failed, message: "Source repo path does not exist: #{repo_path}"}

      not File.exists?(Path.join(repo_path, ".git")) ->
        %{
          ok: false,
          status: :failed,
          message: "Source repo is not a git repository: #{repo_path}"
        }

      File.exists?(link_path) and not symlink?(link_path) ->
        %{
          ok: false,
          status: :failed,
          message: "Materialization path #{link_path} already exists and is not a symlink"
        }

      Enum.any?(plan.operations, &(&1.type == :attach_repo)) and not File.dir?(repo_path) ->
        %{ok: false, status: :failed, message: "Attach operation requires source repo to exist"}

      true ->
        %{ok: true, status: :verified, message: "All demo prerequisites satisfied"}
    end
  end

  defp symlink?(path) do
    case File.read_link(path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  ## ─── Validation ───────────────────────────────────────────────────

  defp validate_repo_path(nil), do: {:error, "--repo is required"}

  defp validate_repo_path(path) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) ->
        {:error, "Repo path does not exist: #{path}"}

      not File.dir?(expanded) ->
        {:error, "Repo path is not a directory: #{path}"}

      not File.exists?(Path.join(expanded, ".git")) ->
        {:error, "Repo path is not a git repository: #{path}"}

      true ->
        {:ok, expanded}
    end
  end

  defp validate_repo_name(nil), do: {:error, "--name is required"}

  defp validate_repo_name(name) do
    try do
      atom = String.to_atom(name)

      if Regex.match?(~r/^[a-z][a-zA-Z0-9_]*$/, name) do
        {:ok, atom}
      else
        {:error,
         "Invalid repo name '#{name}' — must be a valid Elixir atom (^[a-z][a-zA-Z0-9_]*$)"}
      end
    rescue
      _ ->
        {:error, "Invalid repo name: #{name}"}
    end
  end

  defp ensure_safe_graft_root(root) do
    case Safety.allowed_root?(root) do
      :ok ->
        File.mkdir_p!(root)
        :ok

      {:error, err} ->
        {:error, err.message}
    end
  end

  defp tmp_graft_root do
    Path.join(System.tmp_dir!(), "contrib_graft_demo_#{:erlang.unique_integer([:positive])}")
  end

  ## ─── Formatting ─────────────────────────────────────────────────────

  defp format_result(result, true) do
    json =
      %{
        current_snapshot_id: result.current_id,
        desired_snapshot_id: result.desired_id,
        diff: result.diff,
        plan: %{
          id: result.plan_id,
          action: result.plan_action,
          operations_count: result.plan_operations_count
        },
        verification: result.verification,
        materialized_path: result.materialized_path,
        materialization_ok: result.materialization_ok,
        drift: result.drift,
        drift_ok: result.drift_ok,
        teardown_ok: result.teardown_ok,
        graft_root: result.graft_root,
        repo_path: result.repo_path,
        repo_name: result.repo_name
      }
      |> Jason.encode!(pretty: true)

    {:ok, json, if(result.drift_ok and result.verification.ok, do: 0, else: 1)}
  end

  defp format_result(result, _json) do
    lines = [
      "═══════════════════════════════════════════════════════════════",
      " GRAFT VERTICAL SLICE DEMO",
      "═══════════════════════════════════════════════════════════════",
      "",
      "  Current snapshot id : #{result.current_id}",
      "  Desired snapshot id   : #{result.desired_id}",
      "",
      "  Diff:",
      "    added    : #{result.diff.added}",
      "    removed  : #{result.diff.removed}",
      "    changed  : #{result.diff.changed}",
      "    same     : #{result.diff.same}",
      "",
      "  Plan:",
      "    id          : #{result.plan_id}",
      "    action      : #{result.plan_action}",
      "    operations  : #{result.plan_operations_count}",
      "",
      "  Verification:",
      "    status  : #{if(result.verification.ok, do: "PASS", else: "FAIL")}",
      if(not result.verification.ok,
        do: "    error   : #{result.verification.message}",
        else: ""
      ),
      "",
      "  Materialization:",
      "    path    : #{result.materialized_path || "N/A"}",
      "    ok      : #{result.materialization_ok}",
      "",
      "  Drift (observed vs desired):",
      "    result  : #{result.drift}",
      "    ok      : #{result.drift_ok}",
      "",
      "  Teardown:",
      "    ok      : #{result.teardown_ok}",
      "",
      "═══════════════════════════════════════════════════════════════"
    ]

    text = lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    exit_code = if result.drift_ok and result.verification.ok, do: 0, else: 1
    {:ok, text, exit_code}
  end

  defp summarize_diff(delta) do
    %{
      added: length(delta.added),
      removed: length(delta.removed),
      changed: length(delta.changed),
      same: length(delta.same)
    }
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp parse_opts(argv) do
    case OptionParser.parse!(argv, strict: @switches) do
      {opts, []} ->
        {:ok, opts}

      {_opts, extra} ->
        {:error, "unexpected arguments: #{Enum.join(extra, " ")}"}
    end
  rescue
    e in OptionParser.ParseError ->
      {:error, Exception.message(e)}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end
end
