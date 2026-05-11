defmodule Mix.Tasks.Graft.DemoTest do
  use ExUnit.Case

  alias Mix.Tasks.Graft.Demo

  ## ─── Happy path ─────────────────────────────────────────────────────

  test "full vertical slice with a temp git repo" do
    repo_dir = make_temp_git_repo("happy_repo")

    {:ok, output, exit_code} =
      Demo.execute(["--repo", repo_dir, "--name", "happy_repo"])

    assert exit_code == 0, "Expected success but got:\n#{output}"
    assert output =~ "Current snapshot id"
    assert output =~ "Desired snapshot id"
    assert output =~ "PASS"
    assert output =~ "no drift"
    assert output =~ "Teardown:"
    assert output =~ "ok      : true"

    # Verify no symlinks left behind in any graft demo dirs
    assert no_leftover_symlinks_in_graft_dirs?()
  end

  test "full vertical slice with --root inside cwd" do
    repo_dir = make_temp_git_repo("rooted_repo")

    root =
      Path.join(System.tmp_dir!(), "contrib_graft_test_#{:erlang.unique_integer([:positive])}")

    {:ok, output, exit_code} =
      Demo.execute(["--repo", repo_dir, "--name", "rooted_repo", "--root", root])

    assert exit_code == 0
    assert output =~ "Current snapshot id"

    # Cleanup
    File.rm_rf!(root)
  end

  ## ─── Error cases ────────────────────────────────────────────────────

  test "rejects missing --repo" do
    {:error, message, :stderr} = Demo.execute(["--name", "foo"])
    assert message =~ "--repo is required"
  end

  test "rejects missing --name" do
    repo_dir = make_temp_git_repo("nameless")
    {:error, message, :stderr} = Demo.execute(["--repo", repo_dir])
    assert message =~ "--name is required"
  end

  test "rejects non-existent repo path" do
    {:error, message, :stderr} =
      Demo.execute(["--repo", "/nonexistent/path/foo", "--name", "foo"])

    assert message =~ "does not exist"
  end

  test "rejects non-git directory" do
    dir = Path.join(System.tmp_dir!(), "not_a_git_repo_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:error, message, :stderr} =
      Demo.execute(["--repo", dir, "--name", "nongit"])

    assert message =~ "not a git repository"

    File.rm_rf!(dir)
  end

  test "rejects unsafe graft root outside temp and cwd" do
    repo_dir = make_temp_git_repo("unsafe")

    {:error, message, :stderr} =
      Demo.execute([
        "--repo",
        repo_dir,
        "--name",
        "unsafe",
        "--root",
        "/etc/contrib_graft_test"
      ])

    assert message =~ "must be inside temp directory"
  end

  test "rejects invalid repo name" do
    repo_dir = make_temp_git_repo("badname")

    {:error, message, :stderr} =
      Demo.execute(["--repo", repo_dir, "--name", "123-invalid"])

    assert message =~ "Invalid repo name"
  end

  ## ─── Teardown safety ──────────────────────────────────────────────

  test "teardown removes symlink but never source repo" do
    repo_dir = make_temp_git_repo("sacred_source")

    root =
      Path.join(
        System.tmp_dir!(),
        "contrib_graft_teardown_#{:erlang.unique_integer([:positive])}"
      )

    # Materialize manually so we can inspect before teardown
    {:ok, _output, 0} =
      Demo.execute(["--repo", repo_dir, "--name", "sacred_source", "--root", root])

    # After the demo completes, everything should be torn down
    refute File.exists?(Path.join(root, "sacred_source"))

    # But the source repo must still exist
    assert File.dir?(repo_dir)
    assert File.exists?(Path.join(repo_dir, ".git"))

    File.rm_rf!(root)
  end

  ## ─── JSON output ──────────────────────────────────────────────────

  test "outputs valid JSON with --json" do
    repo_dir = make_temp_git_repo("json_repo")

    {:ok, json, exit_code} =
      Demo.execute(["--repo", repo_dir, "--name", "json_repo", "--json"])

    assert exit_code == 0

    decoded = Jason.decode!(json)
    assert decoded["current_snapshot_id"] != nil
    assert decoded["desired_snapshot_id"] != nil
    assert decoded["verification"]["ok"] == true
    assert decoded["drift_ok"] == true
    assert decoded["teardown_ok"] == true
    assert decoded["materialized_path"] != nil
  end

  ## ─── Helpers ──────────────────────────────────────────────────────

  defp make_temp_git_repo(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "contrib_test_repo_#{name}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # Initialize git repo
    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir, stderr_to_stdout: true)

    # Create a dummy file and commit
    File.write!(Path.join(dir, "README.md"), "# #{name}\n")
    System.cmd("git", ["add", "."], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir, stderr_to_stdout: true)

    dir
  end

  defp no_leftover_symlinks_in_graft_dirs? do
    tmp = System.tmp_dir!()

    case File.ls(tmp) do
      {:ok, files} ->
        graft_dirs = Enum.filter(files, &String.starts_with?(&1, "contrib_graft_demo_"))

        Enum.all?(graft_dirs, fn dir ->
          full = Path.join(tmp, dir)

          case File.ls(full) do
            {:ok, entries} ->
              not Enum.any?(entries, fn entry ->
                path = Path.join(full, entry)
                File.exists?(path) and File.lstat!(path).type == :symlink
              end)

            _ ->
              true
          end
        end)

      _ ->
        true
    end
  end
end
