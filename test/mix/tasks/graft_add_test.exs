defmodule Mix.Tasks.Graft.AddTest do
  use ExUnit.Case

  alias Mix.Tasks.Graft.Add

  test "execute requires at least one owner/repo" do
    assert {:error, message} = Add.execute([])
    assert message =~ "Usage"
  end

  test "execute rejects unknown arguments" do
    assert {:error, message} = Add.execute(["--unknown"])
    assert message =~ "unknown"
  end

  test "execute formats results" do
    root = System.tmp_dir!()
    rand = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    repo_dir = Path.join(root, "graft_add_mix_test_#{rand}")
    File.mkdir_p!(repo_dir)

    on_exit(fn -> File.rm_rf!(repo_dir) end)

    # Create a fake repo
    File.mkdir_p!(Path.join(repo_dir, "testrepo"))
    System.cmd("git", ["init", Path.join(repo_dir, "testrepo")], stderr_to_stdout: true)
    System.cmd("git", ["-C", Path.join(repo_dir, "testrepo"), "remote", "add", "origin", "https://github.com/owner/testrepo.git"], stderr_to_stdout: true)
    File.write!(Path.join([repo_dir, "testrepo", "mix.exs"]), "# fake")

    assert {:ok, output} = Add.execute(["--root", repo_dir, "owner/testrepo"])
    assert output =~ "testrepo"
    assert output =~ "✓" or output =~ "[OK]"
  end
end
