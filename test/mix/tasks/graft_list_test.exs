# Uses Mix.Shell.Process + ExUnit.CaptureIO.
# These leak/interfere under async execution due to group-leader
# and mailbox interactions across concurrent Mix-task tests.
defmodule Mix.Tasks.Graft.ListTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Graft.List, as: Task

  describe "execute/1 — success" do
    test "text output for a populated workspace" do
      dir = tmp_dir()
      build_workspace(dir)

      assert {:ok, output} = Task.execute(["--root", dir])
      assert output =~ "Graft workspace:"
      assert output =~ "Siblings (2):"
      assert output =~ "alpha"
      assert output =~ "[present]"
      assert output =~ "beta"
      assert output =~ "[missing]"
    end

    test "json output for a populated workspace" do
      dir = tmp_dir()
      build_workspace(dir)

      assert {:ok, output} = Task.execute(["--json", "--root", dir])

      decoded = Jason.decode!(output)
      assert decoded["sibling_count"] == 2
      assert decoded["root"] == dir

      names = Enum.map(decoded["siblings"], & &1["name"])
      assert "alpha" in names
      assert "beta" in names

      alpha = Enum.find(decoded["siblings"], &(&1["name"] == "alpha"))
      assert alpha["exists"] == true
      assert alpha["status"] == "present"

      beta = Enum.find(decoded["siblings"], &(&1["name"] == "beta"))
      assert beta["exists"] == false
      assert beta["status"] == "missing"
    end

    test "default format is text when --json is omitted" do
      dir = tmp_dir()
      build_workspace(dir)

      assert {:ok, output} = Task.execute(["--root", dir])
      refute output =~ ~r/^\s*\{/
      assert output =~ "Siblings"
    end

    test "empty manifest shows zero siblings" do
      dir = tmp_dir()
      File.write!(Path.join(dir, "graft.exs"), ~s|%{root: ".", siblings: []}|)

      assert {:ok, output} = Task.execute(["--root", dir])
      assert output =~ "Siblings (0):"
    end
  end

  describe "execute/1 — domain errors" do
    test "missing manifest in human mode → stderr text" do
      dir = tmp_dir()
      assert {:error, message, :stderr} = Task.execute(["--root", dir])
      assert message =~ "graft.list:"
      assert message =~ "No graft.exs found"
    end

    test "missing manifest in --json mode → stdout JSON" do
      dir = tmp_dir()
      assert {:error, output, :stdout} = Task.execute(["--json", "--root", dir])

      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "manifest_not_found"
      assert decoded["error"]["message"] =~ "No graft.exs found"
    end

    test "invalid manifest in --json mode preserves structured shape" do
      dir = tmp_dir()
      File.write!(Path.join(dir, "graft.exs"), ":not_a_map")

      assert {:error, output, :stdout} = Task.execute(["--json", "--root", dir])
      assert Jason.decode!(output)["error"]["kind"] == "manifest_invalid_shape"
    end
  end

  describe "execute/1 — argument errors" do
    test "unknown flag → stderr regardless of --json presence" do
      assert {:error, msg, :stderr} = Task.execute(["--bogus"])
      assert msg =~ "graft.list:"

      assert {:error, msg2, :stderr} = Task.execute(["--bogus", "--json"])
      assert msg2 =~ "graft.list:"
    end

    test "unexpected positional arguments → stderr" do
      assert {:error, msg, :stderr} = Task.execute(["spurious"])
      assert msg =~ "unexpected arguments"
      assert msg =~ "spurious"
    end

    test "--root requires a value" do
      assert {:error, msg, :stderr} = Task.execute(["--root"])
      assert msg =~ "graft.list:"
    end
  end

  describe "run/1 — Mix shell wiring" do
    test "success writes to stdout" do
      dir = tmp_dir()
      build_workspace(dir)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Task.run(["--root", dir])
        end)

      assert output =~ "Siblings"
    end

    test "domain error in human mode writes to stderr and exits non-zero" do
      dir = tmp_dir()
      assert catch_exit(Task.run(["--root", dir])) == {:shutdown, 1}
    end

    test "domain error in --json mode writes to stdout and exits non-zero" do
      dir = tmp_dir()
      assert catch_exit(Task.run(["--json", "--root", dir])) == {:shutdown, 1}
    end
  end

  ## ─── Fixtures ───────────────────────────────────────────────────────

  defp tmp_dir do
    rand = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    dir = Path.join(System.tmp_dir!(), "graft_list_mix_test_#{rand}")
    File.mkdir_p!(dir)
    dir
  end

  defp build_workspace(dir) do
    File.mkdir_p!(Path.join(dir, "alpha"))
    File.write!(Path.join([dir, "alpha", "mix.exs"]), "# fake\n")
    # beta is deliberately NOT created — should show [missing]

    File.write!(Path.join(dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        %{name: :alpha, path: "alpha"},
        %{name: :beta, path: "beta"}
      ]
    }
    """)
  end
end
