defmodule Graft.Status do
  @moduledoc """
  Renders a `Graft.Workspace` snapshot as either a human-readable text
  block or a structured JSON string.

  Pure rendering — performs no IO, no filesystem access, no git or mix
  shell-outs, no network calls, and never rescans the workspace. The only
  inputs are the snapshot struct already supplied by the caller.
  """

  alias Graft.{GitState, Workspace}
  alias Graft.Validate.ResultFile
  alias Graft.Validate.ResultFile.Persisted, as: ValidatePersisted
  alias Graft.Workspace.Repo

  @sources [:hex, :path, :git, :unknown]

  @type format :: :text | :json

  @doc """
  Render `workspace` in the chosen format.

  Defaults to `:text`. Returns a binary suitable for printing or piping.
  """
  @spec render(Workspace.t(), format()) :: String.t()
  def render(workspace, format \\ :text)

  def render(%Workspace{} = w, :text), do: render_text(w)
  def render(%Workspace{} = w, :json), do: render_json(w)

  ## ─── Text ───────────────────────────────────────────────────────────

  defp render_text(%Workspace{} = w) do
    git_by_repo = Map.new(w.git, &{&1.repo, &1})

    header = [
      "Graft workspace",
      "Root: #{w.root}",
      "Repos: #{length(w.repos)}",
      "Validation: #{validation_text(w)}",
      ""
    ]

    repo_blocks =
      Enum.flat_map(w.repos, &repo_text_block(&1, w.deps, Map.get(git_by_repo, &1.name)))

    (header ++ repo_blocks)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp repo_text_block(%Repo{} = r, all_deps, git) do
    case repo_status(r) do
      :ok ->
        counts = count_deps(all_deps, r.name)

        [
          to_string(r.name),
          "  status: ok",
          "  git: #{git_text(git)}",
          "  deps: #{format_deps_line(counts)}",
          ""
        ]

      {:missing, msg} ->
        [to_string(r.name), "  status: #{msg}", ""]
    end
  end

  defp git_text(nil), do: "(no git data)"

  defp git_text(%GitState{is_git_repo?: false, error: :git_not_installed}),
    do: "git not installed"

  defp git_text(%GitState{is_git_repo?: false}), do: "not a git repo"

  defp git_text(%GitState{} = g) do
    branch = g.branch || "detached"
    upstream = if g.upstream, do: " ↑ #{g.upstream}", else: " (no upstream)"
    counts = ahead_behind_text(g)
    flags = flag_segments(g)
    base = "#{branch}#{upstream}#{counts}"
    if flags == "", do: base, else: "#{base} #{flags}"
  end

  defp ahead_behind_text(%GitState{ahead: 0, behind: 0}), do: ""
  defp ahead_behind_text(%GitState{ahead: a, behind: 0}), do: " (#{a} ahead)"
  defp ahead_behind_text(%GitState{ahead: 0, behind: b}), do: " (#{b} behind)"
  defp ahead_behind_text(%GitState{ahead: a, behind: b}), do: " (#{a} ahead, #{b} behind)"

  defp flag_segments(%GitState{} = g) do
    [
      if(g.dirty?, do: "dirty", else: nil),
      if(g.detached_head?, do: "detached", else: nil),
      if(g.in_progress != :none, do: Atom.to_string(g.in_progress), else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp validation_text(%Workspace{validate_result: nil}), do: "(none)"

  defp validation_text(%Workspace{validate_result: %ValidatePersisted{} = p} = w) do
    stale = ResultFile.stale?(w, p)
    base = if p.passed?, do: "✓ passed", else: failed_summary(p)

    targets =
      if p.target_apps == [],
        do: "",
        else: " — #{Enum.map_join(p.target_apps, ",", &Atom.to_string/1)} closure"

    stale_flag = if stale, do: " [stale]", else: ""
    "#{base}#{targets}#{stale_flag}"
  end

  defp failed_summary(%ValidatePersisted{first_failure: nil}), do: "✗ failed"

  defp failed_summary(%ValidatePersisted{first_failure: ff}) do
    "✗ failed at #{ff.command_kind} in #{ff.repo} (#{ff.failure_category})"
  end

  defp format_deps_line(counts) do
    Enum.map_join(@sources, " ", fn s -> "#{s}=#{Map.fetch!(counts, s)}" end)
  end

  ## ─── JSON ───────────────────────────────────────────────────────────

  defp render_json(%Workspace{} = w) do
    git_by_repo = Map.new(w.git, &{&1.repo, &1})

    %{
      root: w.root,
      generated_at: maybe_iso8601(w.generated_at),
      repo_count: length(w.repos),
      validation: validation_json(w),
      repos: Enum.map(w.repos, &repo_json(&1, w.deps, Map.get(git_by_repo, &1.name)))
    }
    |> Jason.encode!()
  end

  defp repo_json(%Repo{} = r, all_deps, git) do
    %{
      name: to_string(r.name),
      exists: r.exists?,
      has_mix_exs: r.has_mix_exs?,
      status: status_string(r),
      deps: count_deps(all_deps, r.name),
      git: git_json(git)
    }
  end

  defp validation_json(%Workspace{validate_result: nil}), do: nil

  defp validation_json(%Workspace{validate_result: %ValidatePersisted{} = p} = w) do
    %{
      passed: p.passed?,
      stale: ResultFile.stale?(w, p),
      generated_at: p.generated_at,
      target_apps: Enum.map(p.target_apps, &Atom.to_string/1),
      affected_repos: Enum.map(p.affected_repos, &Atom.to_string/1),
      passed_count: p.passed_count,
      failed_count: p.failed_count,
      skipped_count: p.skipped_count,
      first_failure: encode_first_failure(p.first_failure)
    }
  end

  defp encode_first_failure(nil), do: nil

  defp encode_first_failure(ff) do
    %{
      repo: Atom.to_string(ff.repo),
      command_kind: Atom.to_string(ff.command_kind),
      failure_category: Atom.to_string(ff.failure_category),
      summary: ff.summary
    }
  end

  defp git_json(nil), do: %{is_git_repo: false}

  defp git_json(%GitState{} = g) do
    %{
      is_git_repo: g.is_git_repo?,
      branch: g.branch,
      detached_head: g.detached_head?,
      head_sha: g.head_sha,
      upstream: g.upstream,
      ahead: g.ahead,
      behind: g.behind,
      dirty: g.dirty?,
      in_progress: Atom.to_string(g.in_progress),
      error: if(g.error, do: Atom.to_string(g.error), else: nil)
    }
  end

  ## ─── Shared helpers ─────────────────────────────────────────────────

  defp repo_status(%Repo{exists?: false}), do: {:missing, "missing repo"}
  defp repo_status(%Repo{has_mix_exs?: false}), do: {:missing, "missing mix.exs"}
  defp repo_status(_), do: :ok

  defp status_string(repo) do
    case repo_status(repo) do
      :ok -> "ok"
      {:missing, msg} -> msg
    end
  end

  defp count_deps(all_deps, repo_name) do
    repo_deps = Enum.filter(all_deps, &(&1.repo == repo_name))

    Enum.reduce(@sources, %{}, fn source, acc ->
      Map.put(acc, source, Enum.count(repo_deps, &(&1.source == source)))
    end)
  end

  defp maybe_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp maybe_iso8601(nil), do: nil
end
