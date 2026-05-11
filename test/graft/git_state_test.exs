defmodule Graft.GitStateTest do
  use ExUnit.Case, async: true

  alias Graft.GitState

  @moduletag :tmp_dir

  setup do
    if System.find_executable("git") do
      :ok
    else
      {:skip, "git executable not on PATH"}
    end
  end

  describe "read/2 — not-a-repo cases" do
    test "missing .git/ → is_git_repo? false, error :not_a_repo", %{tmp_dir: tmp_dir} do
      g = GitState.read(tmp_dir)

      assert g.is_git_repo? == false
      assert g.error == :not_a_repo
      assert g.branch == nil
      assert g.dirty? == false
    end
  end

  describe "read/2 — fresh repo with one commit" do
    test "branch + head_sha + clean tree + no upstream", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")

      g = GitState.read(tmp_dir, repo: :sample)

      assert g.is_git_repo? == true
      assert is_binary(g.branch)
      assert g.detached_head? == false
      assert is_binary(g.head_sha)
      assert g.upstream == nil
      assert g.ahead == 0
      assert g.behind == 0
      assert g.dirty? == false
      assert g.in_progress == :none
      assert g.repo == :sample
    end

    test "dirty tree → dirty? true", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")
      File.write!(Path.join(tmp_dir, "scratch.txt"), "untracked")

      assert %GitState{dirty?: true} = GitState.read(tmp_dir)
    end

    test "detached HEAD is flagged", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")
      commit_file(tmp_dir, "second.txt", "two")
      {sha, 0} = System.cmd("git", ["-C", tmp_dir, "rev-parse", "HEAD"], stderr_to_stdout: true)
      sha = String.trim(sha)

      {_, 0} =
        System.cmd("git", ["-C", tmp_dir, "checkout", "--detach", sha], stderr_to_stdout: true)

      g = GitState.read(tmp_dir)
      assert g.detached_head? == true
      assert g.branch == nil
    end
  end

  describe "read/2 — upstream tracking" do
    test "ahead/behind reported against a tracked branch", %{tmp_dir: tmp_dir} do
      upstream = Path.join(tmp_dir, "upstream.git")
      working = Path.join(tmp_dir, "working")

      File.mkdir_p!(upstream)

      {_, 0} =
        System.cmd("git", ["init", "--bare", "-b", "main", upstream], stderr_to_stdout: true)

      init_repo(working, "main")
      commit_file(working, "README.md", "hello")

      {_, 0} =
        System.cmd("git", ["-C", working, "remote", "add", "origin", upstream],
          stderr_to_stdout: true
        )

      {_, 0} =
        System.cmd("git", ["-C", working, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      # 2 commits ahead.
      commit_file(working, "a.txt", "1")
      commit_file(working, "b.txt", "2")

      g = GitState.read(working)
      assert g.upstream == "origin/main"
      assert g.ahead == 2
      assert g.behind == 0
    end
  end

  describe "read/2 — in-progress operations" do
    test "merge marker → :merge", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")
      File.write!(Path.join([tmp_dir, ".git", "MERGE_HEAD"]), "deadbeef\n")

      assert %GitState{in_progress: :merge} = GitState.read(tmp_dir)
    end

    test "rebase-merge directory → :rebase", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")
      File.mkdir_p!(Path.join([tmp_dir, ".git", "rebase-merge"]))

      assert %GitState{in_progress: :rebase} = GitState.read(tmp_dir)
    end

    test "CHERRY_PICK_HEAD → :cherry_pick", %{tmp_dir: tmp_dir} do
      init_repo(tmp_dir)
      commit_file(tmp_dir, "README.md", "hello")
      File.write!(Path.join([tmp_dir, ".git", "CHERRY_PICK_HEAD"]), "deadbeef\n")

      assert %GitState{in_progress: :cherry_pick} = GitState.read(tmp_dir)
    end
  end

  ## ─── helpers ────────────────────────────────────────────────────────

  defp init_repo(path, branch \\ "main") do
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-b", branch, path], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", path, "config", "user.email", "t@t"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", path, "config", "user.name", "Test"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", path, "config", "commit.gpgsign", "false"], stderr_to_stdout: true)
  end

  defp commit_file(path, name, contents) do
    File.write!(Path.join(path, name), contents)
    {_, 0} = System.cmd("git", ["-C", path, "add", name], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", path, "commit", "-m", "add #{name}"], stderr_to_stdout: true)
  end
end
