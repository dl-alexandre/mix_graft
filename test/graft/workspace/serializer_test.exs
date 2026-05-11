defmodule Graft.Workspace.SerializerTest do
  use ExUnit.Case

  alias Graft.Workspace
  alias Graft.Workspace.{Repo, Dependency, Topology}
  alias Graft.GitState

  defp sample_snapshot do
    repos = [
      %Repo{name: :a, path: "a", absolute_path: "/tmp/a", exists?: true, has_mix_exs?: true},
      %Repo{name: :b, path: "b", absolute_path: "/tmp/b", exists?: true, has_mix_exs?: true}
    ]

    deps = [
      %Dependency{repo: :a, app: :b, raw: "{:b, \"~> 1.0\"}", source: :hex}
    ]

    git = [
      %GitState{repo: :a, repo_path: "/tmp/a", is_git_repo?: true, branch: "main"}
    ]

    workspace = %Workspace{
      id: "test-uuid",
      schema_version: 1,
      root: "/tmp",
      generated_at: ~U[2024-01-01T00:00:00Z],
      repos: repos,
      deps: deps,
      git: git
    }

    topology = Topology.from_workspace(workspace)

    %{workspace | topology: topology}
  end

  test "round-trip serialization preserves snapshot" do
    original = sample_snapshot()
    json = Workspace.Serializer.to_json(original)

    assert is_binary(json)
    assert String.contains?(json, "test-uuid")

    {:ok, decoded} = Workspace.Serializer.from_json(json)

    assert decoded.id == original.id
    assert decoded.schema_version == original.schema_version
    assert decoded.root == original.root
    assert length(decoded.repos) == length(original.repos)
    assert length(decoded.deps) == length(original.deps)
    assert length(decoded.git) == length(original.git)
  end

  test "save and load round-trip" do
    snapshot = sample_snapshot()
    path = Path.join(System.tmp_dir!(), "contrib_test_snapshot.json")

    try do
      :ok = Workspace.Serializer.save(path, snapshot)
      assert File.exists?(path)

      {:ok, loaded} = Workspace.Serializer.load(path)
      assert loaded.id == snapshot.id
    after
      File.rm(path)
    end
  end

  test "rejects unsupported schema version" do
    json =
      ~s({"schema_version": 999, "id": "x", "root": "/tmp", "generated_at": "2024-01-01T00:00:00Z", "repos": [], "deps": [], "git": []})

    assert {:error, %Graft.Error{kind: :workspace_unsupported_schema}} =
             Workspace.Serializer.from_json(json)
  end

  test "rejects missing schema version" do
    json = ~s({"id": "x", "root": "/tmp", "generated_at": "2024-01-01T00:00:00Z"})

    assert {:error, %Graft.Error{kind: :workspace_invalid_schema}} =
             Workspace.Serializer.from_json(json)
  end
end
