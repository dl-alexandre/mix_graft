defmodule Graft.TeardownTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Teardown

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "td_test_#{:erlang.unique_integer([:positive])}")
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

  describe "teardown_repo/2" do
    test "removes a symlink" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      File.mkdir_p!(graft_root)
      link = Path.join(graft_root, "sym")
      File.ln_s!(source, link)

      repo = managed_repo(:sym, source)
      assert :ok = Teardown.teardown_repo(repo, graft_root)
      refute File.exists?(link)
      assert File.dir?(source)
    end

    test "is idempotent when symlink already gone" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:gone, source)
      assert :ok = Teardown.teardown_repo(repo, graft_root)
    end

    test "never removes external repos" do
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

      assert :ok = Teardown.teardown_repo(repo, graft_root)
      assert File.dir?(source)
    end

    test "removes empty directories created by mkdir_p" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      dir = Path.join(graft_root, "emptydir")
      File.mkdir_p!(dir)

      repo = managed_repo(:emptydir, source)
      assert :ok = Teardown.teardown_repo(repo, graft_root)
      refute File.exists?(dir)
    end

    test "refuses to remove a non-empty directory" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      dir = Path.join(graft_root, "fulldir")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "file.txt"), "x")

      repo = managed_repo(:fulldir, source)

      assert {:error, %Error{kind: :runner_rollback_failed}} =
               Teardown.teardown_repo(repo, graft_root)

      # Must still be there
      assert File.dir?(dir)
    end

    test "refuses to remove a regular file" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      File.mkdir_p!(graft_root)
      file = Path.join(graft_root, "regular")
      File.write!(file, "not a symlink")

      repo = managed_repo(:regular, source)

      assert {:error, %Error{kind: :runner_rollback_failed}} =
               Teardown.teardown_repo(repo, graft_root)

      assert File.exists?(file)
    end

    test "refuses unsafe graft root" do
      source = tmp_dir()
      File.mkdir_p!(source)

      repo = managed_repo(:unsafe, source)

      assert {:error, %Error{kind: :runner_fence_violation}} =
               Teardown.teardown_repo(repo, "/etc")
    end

    test "refuses path-traversal repo names" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:"../etc", source)

      assert {:error, %Error{kind: :runner_write_failed}} =
               Teardown.teardown_repo(repo, graft_root)
    end
  end

  describe "teardown_workspace/2" do
    test "tears down all managed repos in a snapshot" do
      source_a = tmp_dir()
      source_b = tmp_dir()
      File.mkdir_p!(source_a)
      File.mkdir_p!(source_b)
      graft_root = tmp_dir()

      File.mkdir_p!(graft_root)
      File.ln_s!(source_a, Path.join(graft_root, "a"))
      File.ln_s!(source_b, Path.join(graft_root, "b"))

      ws = %Workspace{
        repos: [
          managed_repo(:a, source_a),
          managed_repo(:b, source_b)
        ]
      }

      assert :ok = Teardown.teardown_workspace(ws, graft_root)
      refute File.exists?(Path.join(graft_root, "a"))
      refute File.exists?(Path.join(graft_root, "b"))
      assert File.dir?(source_a)
      assert File.dir?(source_b)
    end

    test "stops on first error" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      File.mkdir_p!(graft_root)
      File.mkdir_p!(Path.join(graft_root, "good"))
      File.write!(Path.join(graft_root, "bad"), "not a symlink")

      ws = %Workspace{
        repos: [
          managed_repo(:good, source),
          managed_repo(:bad, source)
        ]
      }

      # Order matters — :good comes before :bad alphabetically
      assert {:error, %Error{kind: :runner_rollback_failed}} =
               Teardown.teardown_workspace(ws, graft_root)
    end
  end
end
