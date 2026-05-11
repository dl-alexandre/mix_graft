defmodule Graft.AddTest do
  use ExUnit.Case

  alias Graft.Add
  alias Graft.Error

  defp tmp_root do
    rand = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    dir = Path.join(System.tmp_dir!(), "graft_add_test_#{rand}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest(root, content) do
    path = Path.join(root, "graft.exs")
    File.write!(path, inspect(content) <> "\n")
    path
  end

  ## ─── Parse ────────────────────────────────────────────────────────

  test "clone with empty list returns empty map" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    assert Add.clone([], root) == %{}
  end

  test "clone with invalid format skips bad entries" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)
    results = Add.clone(["bad-format", "owner/repo"], root)
    assert map_size(results) == 1
    assert {"owner/repo", {:error, %Error{}}} = Enum.at(results, 0)
  end

  test "clone skips already-existing directory with matching remote" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repo_dir = Path.join(root, "repo")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/owner/repo.git"], stderr_to_stdout: true)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake mix.exs")

    results = Add.clone(["owner/repo"], root)
    assert {"owner/repo", :ok} = Enum.at(results, 0)
  end

  test "clone fails when directory exists with different remote" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repo_dir = Path.join(root, "repo")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/other/repo.git"], stderr_to_stdout: true)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake mix.exs")

    results = Add.clone(["owner/repo"], root)
    assert {"owner/repo", {:error, %Error{kind: :clone_destination_exists}}} = Enum.at(results, 0)
  end

  test "clone fails when directory exists but is not a git repo" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repo_dir = Path.join(root, "repo")
    File.mkdir_p!(repo_dir)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake mix.exs")

    results = Add.clone(["owner/repo"], root)
    assert {"owner/repo", {:error, %Error{kind: :clone_destination_exists}}} = Enum.at(results, 0)
  end

  test "clone fails when repo has no mix.exs" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    # Create an empty git repo
    repo_dir = Path.join(root, "repo")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/owner/repo.git"], stderr_to_stdout: true)

    results = Add.clone(["owner/repo"], root)
    assert {"owner/repo", {:error, %Error{kind: :repo_not_elixir}}} = Enum.at(results, 0)
  end

  test "clone rejects symlink that escapes the root" do
    root = tmp_root()
    outside = Path.join(System.tmp_dir!(), "graft_add_outside_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}")
    File.mkdir_p!(outside)
    link = Path.join(root, "repo")

    on_exit(fn ->
      File.rm(link)
      File.rm_rf!(outside)
      File.rm_rf!(root)
    end)

    :ok = :file.make_symlink(String.to_charlist(outside), String.to_charlist(link))

    results = Add.clone(["owner/repo"], root)
    assert {"owner/repo", {:error, %Error{kind: :runner_fence_violation}}} = Enum.at(results, 0)
  end

  ## ─── Manifest ─────────────────────────────────────────────────────

  test "clone with --to-manifest creates graft.exs when absent" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    # Create the repo directory with matching remote so clone succeeds
    repo_dir = Path.join(root, "flow")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/elixir-lang/flow.git"], stderr_to_stdout: true)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake")

    refute File.exists?(Path.join(root, "graft.exs"))

    results = Add.clone(["elixir-lang/flow"], root, to_manifest: true)
    assert {"elixir-lang/flow", :ok} = Enum.at(results, 0)

    assert File.exists?(Path.join(root, "graft.exs"))

    {:ok, manifest} = Graft.Manifest.load(root)
    assert length(manifest.siblings) == 1
    assert hd(manifest.siblings).name == :flow
  end

  test "clone with --to-manifest appends to graft.exs" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    write_manifest(root, %{
      root: ".",
      siblings: [%{name: :existing, path: "existing"}]
    })

    # Create the repo directory with matching remote so clone succeeds
    repo_dir = Path.join(root, "new_repo")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/owner/new_repo.git"], stderr_to_stdout: true)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake")

    results = Add.clone(["owner/new_repo"], root, to_manifest: true)
    assert {"owner/new_repo", :ok} = Enum.at(results, 0)

    # Verify manifest was updated
    {:ok, manifest} = Graft.Manifest.load(root)
    names = Enum.map(manifest.siblings, & &1.name)
    assert :existing in names
    assert :new_repo in names
  end

  test "clone with --to-manifest skips duplicate names" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf!(root) end)

    write_manifest(root, %{
      root: ".",
      siblings: [%{name: :existing, path: "existing"}]
    })

    repo_dir = Path.join(root, "existing")
    File.mkdir_p!(repo_dir)
    System.cmd("git", ["init", repo_dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", repo_dir, "remote", "add", "origin", "https://github.com/owner/existing.git"], stderr_to_stdout: true)
    File.write!(Path.join(repo_dir, "mix.exs"), "# fake")

    results = Add.clone(["owner/existing"], root, to_manifest: true)
    assert {"owner/existing", :ok} = Enum.at(results, 0)

    # Manifest should still only have one :existing
    {:ok, manifest} = Graft.Manifest.load(root)
    assert length(manifest.siblings) == 1
  end
end
