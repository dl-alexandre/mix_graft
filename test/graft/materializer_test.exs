defmodule Graft.MaterializerTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Materializer

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "mat_test_#{:erlang.unique_integer([:positive])}")
  end

  defp managed_repo(name, abs) do
    %Workspace.Repo{
      name: name,
      path: Atom.to_string(name),
      absolute_path: abs,
      exists?: true,
      has_mix_exs?: true,
      ownership: :managed
    }
  end

  describe "materialize_repo/2" do
    test "creates a symlink for a managed repo" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:myrepo, source)
      assert {:ok, %{myrepo: path}} = Materializer.materialize_repo(repo, graft_root)
      assert path == Path.join(graft_root, "myrepo")
      assert File.exists?(path)
      assert {:ok, ^source} = File.read_link(path)
    end

    test "is idempotent for correct symlinks" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:idempo, source)
      assert {:ok, _} = Materializer.materialize_repo(repo, graft_root)
      assert {:ok, %{idempo: path}} = Materializer.materialize_repo(repo, graft_root)
      assert {:ok, ^source} = File.read_link(path)
    end

    test "rejects external repos" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = %Workspace.Repo{
        name: :ext,
        path: "ext",
        absolute_path: source,
        exists?: true,
        has_mix_exs?: true,
        ownership: :external
      }

      assert {:error, %Error{kind: :runner_write_failed}} =
               Materializer.materialize_repo(repo, graft_root)
    end

    test "rejects unsafe graft root" do
      source = tmp_dir()
      File.mkdir_p!(source)

      repo = managed_repo(:unsafe_root, source)

      assert {:error, %Error{kind: :runner_fence_violation}} =
               Materializer.materialize_repo(repo, "/etc")
    end

    test "rejects path-traversal repo names" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:"../etc", source)

      assert {:error, %Error{kind: :runner_write_failed}} =
               Materializer.materialize_repo(repo, graft_root)
    end

    test "errors when existing path points elsewhere" do
      source_a = tmp_dir()
      source_b = tmp_dir()
      File.mkdir_p!(source_a)
      File.mkdir_p!(source_b)
      graft_root = tmp_dir()
      collision_path = Path.join(graft_root, "collision")

      File.mkdir_p!(graft_root)
      File.rm(collision_path)
      File.ln_s!(source_a, collision_path)

      repo = managed_repo(:collision, source_b)

      assert {:error, %Error{kind: :runner_write_failed}} =
               Materializer.materialize_repo(repo, graft_root)
    end

    test "errors when existing path is a real directory" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      File.mkdir_p!(graft_root)
      File.mkdir_p!(Path.join(graft_root, "realdir"))

      repo = managed_repo(:realdir, source)

      assert {:error, %Error{kind: :runner_write_failed}} =
               Materializer.materialize_repo(repo, graft_root)
    end
  end
end
