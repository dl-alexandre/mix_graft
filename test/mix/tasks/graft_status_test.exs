# Uses Mix.Shell.Process + ExUnit.CaptureIO.
# These leak/interfere under async execution due to group-leader
# and mailbox interactions across concurrent Mix-task tests.
defmodule Mix.Tasks.Graft.StatusTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Graft.Status, as: Task

  @moduletag :tmp_dir

  describe "execute/1 — success" do
    test "text output for a populated workspace", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir)

      assert {:ok, output} = Task.execute(["--root", tmp_dir])
      assert output =~ "Graft workspace"
      assert output =~ "Repos: 1"
      assert output =~ "alpha"
      assert output =~ "  status: ok"
      assert output =~ "  deps: hex=1 path=0 git=0 unknown=0"
    end

    test "json output for a populated workspace", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir)

      assert {:ok, output} = Task.execute(["--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["repo_count"] == 1
      [alpha] = decoded["repos"]
      assert alpha["name"] == "alpha"
      assert alpha["status"] == "ok"
      assert alpha["deps"]["hex"] == 1
    end

    test "default format is text when --json is omitted", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir)

      assert {:ok, output} = Task.execute(["--root", tmp_dir])
      refute output =~ ~r/^\s*\{/
      assert output =~ "Graft workspace"
    end
  end

  describe "execute/1 — domain errors" do
    test "missing manifest in human mode → stderr text", %{tmp_dir: tmp_dir} do
      assert {:error, message, :stderr} = Task.execute(["--root", tmp_dir])
      assert message =~ "graft.status:"
      assert message =~ "No graft.exs found"
    end

    test "missing manifest in --json mode → stdout JSON", %{tmp_dir: tmp_dir} do
      assert {:error, output, :stdout} = Task.execute(["--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "manifest_not_found"
      assert decoded["error"]["message"] =~ "No graft.exs found"
      assert is_map(decoded["error"]["details"])
      assert decoded["error"]["details"]["path"] =~ "graft.exs"
    end

    test "invalid manifest in --json mode preserves structured shape",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "graft.exs"), ":not_a_map")

      assert {:error, output, :stdout} = Task.execute(["--json", "--root", tmp_dir])
      assert Jason.decode!(output)["error"]["kind"] == "manifest_invalid_shape"
    end
  end

  describe "execute/1 — argument errors" do
    test "unknown flag → stderr regardless of --json presence" do
      assert {:error, msg, :stderr} = Task.execute(["--bogus"])
      assert msg =~ "graft.status:"

      # Even if --json is also present, arg errors stay human (we can't
      # trust the parse).
      assert {:error, msg2, :stderr} = Task.execute(["--bogus", "--json"])
      assert msg2 =~ "graft.status:"
    end

    test "unexpected positional arguments → stderr" do
      assert {:error, msg, :stderr} = Task.execute(["spurious"])
      assert msg =~ "unexpected arguments"
      assert msg =~ "spurious"
    end

    test "--root requires a value" do
      assert {:error, msg, :stderr} = Task.execute(["--root"])
      assert msg =~ "graft.status:"
    end
  end

  describe "run/1 — Mix shell wiring" do
    test "success writes to stdout", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Task.run(["--root", tmp_dir])
        end)

      assert output =~ "Graft workspace"
    end

    test "domain error in human mode writes to stderr and exits non-zero",
         %{tmp_dir: tmp_dir} do
      assert catch_exit(Task.run(["--root", tmp_dir])) == {:shutdown, 1}
    end

    test "domain error in --json mode writes to stdout and exits non-zero",
         %{tmp_dir: tmp_dir} do
      assert catch_exit(Task.run(["--json", "--root", tmp_dir])) == {:shutdown, 1}
    end
  end

  ## ─── Fixture ────────────────────────────────────────────────────────

  defp build_workspace(tmp_dir) do
    sibling = Path.join(tmp_dir, "alpha")
    File.mkdir_p!(sibling)

    File.write!(Path.join(sibling, "mix.exs"), """
    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, version: "0.1.0", deps: deps()]
      defp deps do
        [{:foo, "~> 1.0"}]
      end
    end
    """)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [%{name: :alpha, path: "alpha"}]
    }
    """)
  end
end
