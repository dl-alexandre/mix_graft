defmodule Graft.Link.Plan.Render do
  @moduledoc """
  Pure rendering of `Graft.Link.Plan` values for CLI consumption.

  Two formats:

    * `:text` — human-readable summary + per-change blocks.
    * `:json` — structured map serialized via Jason; deterministic
      ordering for agent/jq consumption.

  Performs no IO and does not rescan or mutate the plan.
  """

  alias Graft.CLI.Errors
  alias Graft.Link.Plan
  alias Graft.Link.Plan.Change
  alias Graft.Link.Runner.Result

  @type format :: :text | :json

  @spec render(Plan.t(), format()) :: String.t()
  def render(plan, format \\ :text)
  def render(%Plan{} = plan, :text), do: render_text(plan)
  def render(%Plan{} = plan, :json), do: render_json(plan)

  @spec render_applied(Plan.t(), Result.t(), format()) :: String.t()
  def render_applied(plan, result, format \\ :text)

  def render_applied(%Plan{} = plan, %Result{} = result, :text),
    do: render_applied_text(plan, result)

  def render_applied(%Plan{} = plan, %Result{} = result, :json),
    do: render_applied_json(plan, result)

  ## ─── Text ───────────────────────────────────────────────────────────

  defp render_text(%Plan{} = plan) do
    header = [
      "Graft link.#{operation_label(plan.operation)} (dry-run)",
      "Workspace: #{plan.workspace_root}",
      "Targets: #{Enum.map_join(plan.target_apps, ", ", &Atom.to_string/1)}",
      "Affected repos: #{length(plan.affected_repos)}",
      "Changes: #{length(plan.changes)}",
      ""
    ]

    body =
      case plan.changes do
        [] -> ["(no changes required)"]
        changes -> Enum.flat_map(changes, &change_block/1)
      end

    warnings =
      case plan.warnings do
        [] -> []
        ws -> ["", "Warnings:" | Enum.map(ws, &"  - #{&1}")]
      end

    (header ++ body ++ warnings)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp change_block(%Change{} = c) do
    [
      "#{c.repo} → #{c.target_app}",
      "  before: #{c.dependency_source_before}",
      "  after:  #{c.dependency_source_after}",
      "  changed: #{if c.changed?, do: "yes", else: "no"}",
      ""
    ]
  end

  defp operation_label(:link_on), do: "on"
  defp operation_label(:link_off), do: "off"

  ## ─── JSON ───────────────────────────────────────────────────────────

  defp render_json(%Plan{} = plan) do
    %{
      operation: to_string(plan.operation),
      dry_run: true,
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(plan.generated_at),
      target_apps: Enum.map(plan.target_apps, &Atom.to_string/1),
      affected_repos: Enum.map(plan.affected_repos, &Atom.to_string/1),
      changes: Enum.map(plan.changes, &change_json/1),
      warnings: plan.warnings
    }
    |> Errors.jsonable()
    |> Jason.encode!()
  end

  ## ─── Applied (text) ─────────────────────────────────────────────────

  defp render_applied_text(%Plan{} = plan, %Result{} = result) do
    header = [
      "Graft link.#{operation_label(plan.operation)} (applied)",
      "Workspace: #{plan.workspace_root}",
      "Targets: #{Enum.map_join(plan.target_apps, ", ", &Atom.to_string/1)}",
      "Affected repos: #{length(plan.affected_repos)}",
      "Applied changes: #{length(result.applied_changes)}",
      "State: #{result.state_path}",
      "Duration: #{result.duration_ms}ms",
      ""
    ]

    body =
      case result.applied_changes do
        [] -> ["(no changes applied)"]
        changes -> Enum.map(changes, fn c -> "  #{c.repo} → #{c.target_app}" end)
      end

    (header ++ body)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  ## ─── Applied (JSON) ─────────────────────────────────────────────────

  defp render_applied_json(%Plan{} = plan, %Result{} = result) do
    %{
      operation: to_string(plan.operation),
      dry_run: false,
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(plan.generated_at),
      target_apps: Enum.map(plan.target_apps, &Atom.to_string/1),
      affected_repos: Enum.map(plan.affected_repos, &Atom.to_string/1),
      applied_changes: Enum.map(result.applied_changes, &applied_change_json/1),
      state_path: result.state_path,
      duration_ms: result.duration_ms,
      warnings: plan.warnings
    }
    |> Errors.jsonable()
    |> Jason.encode!()
  end

  defp applied_change_json(%Change{} = c) do
    %{
      repo: to_string(c.repo),
      repo_path: c.repo_path,
      target_app: to_string(c.target_app),
      dependency_source_before: c.dependency_source_before,
      dependency_source_after: c.dependency_source_after,
      mix_exs_before_hash: c.mix_exs_before_hash,
      mix_exs_after_hash: c.proposed_mix_exs_after_hash
    }
  end

  defp change_json(%Change{} = c) do
    %{
      repo: to_string(c.repo),
      repo_path: c.repo_path,
      target_app: to_string(c.target_app),
      dependency_source_before: c.dependency_source_before,
      dependency_source_after: c.dependency_source_after,
      mix_exs_before_hash: c.mix_exs_before_hash,
      proposed_mix_exs_after_hash: c.proposed_mix_exs_after_hash,
      changed: c.changed?
    }
  end
end
