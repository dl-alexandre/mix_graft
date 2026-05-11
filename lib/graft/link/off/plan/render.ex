defmodule Graft.Link.Off.Plan.Render do
  @moduledoc """
  Pure rendering of `Graft.Link.Off.Plan` and applied results.
  """

  alias Graft.CLI.Errors
  alias Graft.Link.Off.Plan
  alias Graft.Link.Off.Plan.Restoration
  alias Graft.Link.Off.Runner.Result

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

  ## ─── Dry-run text ───────────────────────────────────────────────────

  defp render_text(%Plan{} = plan) do
    header = [
      "Graft link.off (dry-run)",
      "Workspace: #{plan.workspace_root}",
      "Targets: #{Enum.map_join(plan.target_apps, ", ", &Atom.to_string/1)}",
      "Affected repos: #{length(plan.affected_repos)}",
      "Restorations: #{length(plan.restorations)}",
      "Remaining linked apps: #{render_atom_list(plan.remaining_target_apps)}",
      ""
    ]

    body =
      case plan.restorations do
        [] -> ["(no restorations required)"]
        rs -> Enum.flat_map(rs, &restoration_block/1)
      end

    (header ++ body)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp restoration_block(%Restoration{} = r) do
    [
      "#{r.repo} ← #{r.target_app}",
      "  from: #{r.replacement}",
      "  to:   #{r.preimage}",
      ""
    ]
  end

  defp render_atom_list([]), do: "(none)"
  defp render_atom_list(atoms), do: Enum.map_join(atoms, ", ", &Atom.to_string/1)

  ## ─── Dry-run JSON ───────────────────────────────────────────────────

  defp render_json(%Plan{} = plan) do
    %{
      operation: "link_off",
      dry_run: true,
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(plan.generated_at),
      target_apps: Enum.map(plan.target_apps, &Atom.to_string/1),
      affected_repos: Enum.map(plan.affected_repos, &Atom.to_string/1),
      restorations: Enum.map(plan.restorations, &restoration_json/1),
      remaining_target_apps: Enum.map(plan.remaining_target_apps, &Atom.to_string/1),
      remaining_entries: length(plan.remaining_entries),
      warnings: plan.warnings
    }
    |> Errors.jsonable()
    |> Jason.encode!()
  end

  defp restoration_json(%Restoration{} = r) do
    %{
      repo: to_string(r.repo),
      repo_path: r.repo_path,
      target_app: to_string(r.target_app),
      mix_exs_path: r.mix_exs_path,
      preimage: r.preimage,
      replacement: r.replacement,
      mix_exs_before_hash: r.mix_exs_before_hash,
      mix_exs_after_hash: r.mix_exs_after_hash
    }
  end

  ## ─── Applied text ───────────────────────────────────────────────────

  defp render_applied_text(%Plan{} = plan, %Result{} = result) do
    header = [
      "Graft link.off (applied)",
      "Workspace: #{plan.workspace_root}",
      "Targets: #{Enum.map_join(plan.target_apps, ", ", &Atom.to_string/1)}",
      "Affected repos: #{length(plan.affected_repos)}",
      "Restored: #{length(result.restored)}",
      "Removed state entries: #{length(result.restored)}",
      "Remaining state entries: #{result.remaining_entries}",
      "Remaining linked apps: #{render_atom_list(result.remaining_target_apps)}",
      "State: #{state_line(result)}",
      "Duration: #{result.duration_ms}ms",
      ""
    ]

    body =
      case result.restored do
        [] -> ["(no restorations applied)"]
        rs -> Enum.map(rs, fn r -> "  #{r.repo} ← #{r.target_app}" end)
      end

    (header ++ body)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp state_line(%Result{state_deleted?: true, state_path: p}), do: "#{p} (deleted)"
  defp state_line(%Result{state_path: p}), do: p

  ## ─── Applied JSON ───────────────────────────────────────────────────

  defp render_applied_json(%Plan{} = plan, %Result{} = result) do
    %{
      operation: "link_off",
      dry_run: false,
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(plan.generated_at),
      target_apps: Enum.map(plan.target_apps, &Atom.to_string/1),
      affected_repos: Enum.map(plan.affected_repos, &Atom.to_string/1),
      restored: Enum.map(result.restored, &restored_json/1),
      remaining_target_apps: Enum.map(result.remaining_target_apps, &Atom.to_string/1),
      remaining_entries: result.remaining_entries,
      state_path: result.state_path,
      state_deleted: result.state_deleted?,
      duration_ms: result.duration_ms
    }
    |> Errors.jsonable()
    |> Jason.encode!()
  end

  defp restored_json(%Restoration{} = r) do
    %{
      repo: to_string(r.repo),
      repo_path: r.repo_path,
      target_app: to_string(r.target_app),
      mix_exs_path: r.mix_exs_path,
      preimage: r.preimage,
      replacement: r.replacement
    }
  end
end
