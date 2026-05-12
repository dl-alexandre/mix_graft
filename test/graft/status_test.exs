defmodule Graft.StatusTest do
  use ExUnit.Case, async: true

  alias Graft.{Status, Workspace}
  alias Graft.GitState
  alias Graft.Workspace.{Dependency, Repo}

  describe "render/2 — :text" do
    test "renders header + per-repo blocks" do
      ws = workspace_with_three_repos()

      out = Status.render(ws, :text)

      assert out =~ "Graft workspace"
      assert out =~ "Root: /tmp/oss"
      assert out =~ "Repos: 3"

      # ok repo: status + deps line
      assert out =~ "req_llm"
      assert out =~ "  status: ok"
      assert out =~ "  deps: hex=2 path=1 git=0 unknown=0"

      # missing-mix.exs repo
      assert out =~ "jido_ai"
      assert out =~ "  status: missing mix.exs"

      # missing-repo repo
      assert out =~ "phoenix"
      assert out =~ "  status: missing repo"
    end

    test "default format is :text" do
      ws = workspace_with_three_repos()
      assert Status.render(ws) == Status.render(ws, :text)
    end

    test "missing repos do not get a deps line in text output" do
      ws = workspace_with_three_repos()
      out = Status.render(ws, :text)

      [_, _, jido_block, _] = String.split(out, "\n\n", parts: 4)
      refute jido_block =~ "deps:"
    end

    test "ok repos always show all four source counts, including zeros" do
      ws = %Workspace{
        root: "/tmp/oss",
        generated_at: ~U[2026-01-01 00:00:00Z],
        repos: [%Repo{name: :solo, path: "solo", exists?: true, has_mix_exs?: true}],
        deps: [%Dependency{repo: :solo, app: :foo, raw: "{:foo, ...}", source: :hex}]
      }

      assert Status.render(ws, :text) =~ "deps: hex=1 path=0 git=0 unknown=0"
    end

    test "shows clean or dirty git state and remote mismatch when origin is known" do
      ws = %Workspace{
        root: "/tmp/oss",
        generated_at: ~U[2026-01-01 00:00:00Z],
        repos: [
          %Repo{
            name: :solo,
            path: "solo",
            exists?: true,
            has_mix_exs?: true,
            origin: "https://github.com/owner/solo.git"
          }
        ],
        deps: [],
        git: [
          %GitState{
            repo: :solo,
            is_git_repo?: true,
            branch: "main",
            origin_url: "https://github.com/other/solo.git",
            dirty?: false
          }
        ]
      }

      out = Status.render(ws, :text)
      assert out =~ "git: main (no upstream) clean"
      assert out =~ "remote: mismatch expected https://github.com/owner/solo.git"
    end

    test "header preserves manifest declaration order" do
      ws = workspace_with_three_repos()
      out = Status.render(ws, :text)

      idx = fn substr -> :binary.match(out, substr) |> elem(0) end
      assert idx.("req_llm") < idx.("jido_ai")
      assert idx.("jido_ai") < idx.("phoenix")
    end
  end

  describe "render/2 — :json" do
    test "produces a parseable JSON document with the canonical shape" do
      ws = workspace_with_three_repos()
      json = Status.render(ws, :json)

      decoded = Jason.decode!(json)

      assert decoded["root"] == "/tmp/oss"
      assert decoded["repo_count"] == 3
      assert decoded["generated_at"] == "2026-01-01T00:00:00Z"
      assert is_list(decoded["repos"])
      assert length(decoded["repos"]) == 3
    end

    test "encodes per-repo fields including deps counts" do
      ws = workspace_with_three_repos()
      json = Status.render(ws, :json)
      decoded = Jason.decode!(json)

      [req_llm, jido_ai, phoenix] = decoded["repos"]

      assert req_llm["name"] == "req_llm"
      assert req_llm["exists"] == true
      assert req_llm["has_mix_exs"] == true
      assert req_llm["status"] == "ok"
      assert req_llm["origin"]["expected"] == nil
      assert req_llm["origin"]["matches"] == nil
      assert req_llm["deps"] == %{"hex" => 2, "path" => 1, "git" => 0, "unknown" => 0}
      assert is_map(req_llm["git"])
      assert req_llm["git"]["is_git_repo"] == false

      assert jido_ai["status"] == "missing mix.exs"
      assert jido_ai["exists"] == true
      assert jido_ai["has_mix_exs"] == false
      # JSON shape stays consistent: deps is always present (zeros).
      assert jido_ai["deps"] == %{"hex" => 0, "path" => 0, "git" => 0, "unknown" => 0}

      assert phoenix["status"] == "missing repo"
      assert phoenix["exists"] == false
      assert phoenix["has_mix_exs"] == false
    end

    test "JSON repo order matches snapshot order (deterministic)" do
      ws = workspace_with_three_repos()
      decoded = Jason.decode!(Status.render(ws, :json))

      assert Enum.map(decoded["repos"], & &1["name"]) == ["req_llm", "jido_ai", "phoenix"]
    end
  end

  describe "render/2 — determinism" do
    test "same snapshot renders byte-identically every time (text)" do
      ws = workspace_with_three_repos()
      assert Status.render(ws, :text) == Status.render(ws, :text)
    end

    test "same snapshot renders byte-identically every time (json)" do
      ws = workspace_with_three_repos()
      assert Status.render(ws, :json) == Status.render(ws, :json)
    end

    test "render is pure: snapshot is unchanged after rendering" do
      ws = workspace_with_three_repos()
      _ = Status.render(ws, :text)
      _ = Status.render(ws, :json)
      assert ws == workspace_with_three_repos()
    end
  end

  ## ─── Fixture ────────────────────────────────────────────────────────

  defp workspace_with_three_repos do
    %Workspace{
      root: "/tmp/oss",
      generated_at: ~U[2026-01-01 00:00:00Z],
      repos: [
        %Repo{name: :req_llm, path: "req_llm", exists?: true, has_mix_exs?: true},
        %Repo{name: :jido_ai, path: "jido_ai", exists?: true, has_mix_exs?: false},
        %Repo{name: :phoenix, path: "phoenix", exists?: false, has_mix_exs?: false}
      ],
      deps: [
        %Dependency{repo: :req_llm, app: :foo, raw: "{:foo, ...}", source: :hex},
        %Dependency{repo: :req_llm, app: :bar, raw: "{:bar, ...}", source: :hex},
        %Dependency{repo: :req_llm, app: :baz, raw: "{:baz, ...}", source: :path}
      ]
    }
  end
end
