defmodule Graft.Workspace.DiffTest do
  use ExUnit.Case

  alias Graft.Workspace
  alias Graft.Workspace.{Repo, Dependency, Diff}

  defp base_snapshot do
    %Workspace{
      id: "before",
      schema_version: 1,
      root: "/tmp",
      generated_at: ~U[2024-01-01T00:00:00Z],
      repos: [
        %Repo{name: :a, path: "a", absolute_path: "/tmp/a", exists?: true, has_mix_exs?: true},
        %Repo{name: :b, path: "b", absolute_path: "/tmp/b", exists?: true, has_mix_exs?: true}
      ],
      deps: [
        %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex}
      ],
      git: []
    }
  end

  test "empty diff between identical snapshots" do
    a = base_snapshot()
    b = base_snapshot()
    delta = Diff.diff(a, b)

    assert Diff.empty?(delta)
    assert delta.from_id == a.id
    assert delta.to_id == b.id
  end

  test "detects added repo" do
    a = base_snapshot()

    b = %{
      a
      | repos:
          a.repos ++
            [
              %Repo{
                name: :c,
                path: "c",
                absolute_path: "/tmp/c",
                exists?: true,
                has_mix_exs?: true
              }
            ]
    }

    delta = Diff.diff(a, b)

    refute Diff.empty?(delta)
    assert length(delta.added) == 1
    assert hd(delta.added).path == [:repos, :c]
  end

  test "detects removed repo" do
    a = base_snapshot()
    b = %{a | repos: tl(a.repos)}
    delta = Diff.diff(a, b)

    refute Diff.empty?(delta)
    assert length(delta.removed) >= 1
    removed_paths = Enum.map(delta.removed, & &1.path)
    assert [:repos, :a] in removed_paths or [:repos, :b] in removed_paths
  end

  test "detects changed repo field" do
    a = base_snapshot()
    [first | rest] = a.repos
    b = %{a | repos: [%{first | exists?: false} | rest]}
    delta = Diff.diff(a, b)

    refute Diff.empty?(delta)
    changed_paths = Enum.map(delta.changed, & &1.path)
    assert [:repos, :a, :exists?] in changed_paths
  end

  test "for_repo filters by repo name" do
    a = base_snapshot()
    b = %{a | repos: tl(a.repos)}
    delta = Diff.diff(a, b)

    a_entries = Diff.for_repo(delta, :a)
    b_entries = Diff.for_repo(delta, :b)

    assert length(a_entries) > 0 or length(b_entries) > 0
  end
end
