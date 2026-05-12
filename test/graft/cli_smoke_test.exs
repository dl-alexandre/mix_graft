defmodule Graft.CLISmokeTest do
  # Real end-to-end Mix.Task.rerun/2 smoke tests for the mutation
  # commands. Uses Mix.Shell.Process to capture stdout/stderr. Runs
  # synchronously because `Mix.shell/1` is process-global state and
  # rerunning a Mix task touches the Mix task registry.
  use ExUnit.Case, async: false

  alias Graft.Lock

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    build_fixture(tmp_dir)
    :ok
  end

  test "mix graft.status (text)", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.status", ["--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Graft workspace"
    assert output =~ "jido_ai"
    assert output =~ "req_llm"
  end

  test "mix graft.status --json", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.status", ["--json", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["repo_count"] == 2
    names = decoded["repos"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["jido_ai", "req_llm"]
  end

  test "mix graft.link.on (text)", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.link.on", ["req_llm", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Graft link.on (applied)"
    assert output =~ "jido_ai → req_llm"
    assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~ ~s|path: "../req_llm"|
  end

  test "mix graft.link.on --json", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.link.on", ["req_llm", "--json", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["operation"] == "link_on"
    assert decoded["dry_run"] == false
    assert length(decoded["applied_changes"]) == 1
  end

  test "mix graft.link.off (text) after on", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.link.on", ["req_llm", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [_]}

    Mix.Task.rerun("graft.link.off", ["req_llm", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Graft link.off (applied)"
    assert output =~ "jido_ai ← req_llm"
    assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~ ~s|{:req_llm, "~> 1.0"}|
  end

  test "mix graft.link.off --json after on", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.link.on", ["req_llm", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [_]}

    Mix.Task.rerun("graft.link.off", ["req_llm", "--json", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["operation"] == "link_off"
    assert decoded["state_deleted"] == true
  end

  test "mix graft.validate --dry-run (text)", %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.validate", ["req_llm", "--dry-run", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Graft validate (dry-run)"
    assert output =~ "1. req_llm"
    assert output =~ "2. jido_ai"
  end

  test "mix graft.validate --dry-run --json emits JSONL plan stream",
       %{tmp_dir: tmp_dir} do
    Mix.Task.rerun("graft.validate", ["req_llm", "--dry-run", "--json", "--root", tmp_dir])
    assert_received {:mix_shell, :info, [output]}

    events =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    types = Enum.map(events, & &1["event"])
    assert "plan_started" in types
    assert "plan_completed" in types
    assert "repo_planned" in types
    assert "validation_planned" in types
  end

  test "empty workspace add/list/quick/status/remove happy path", %{tmp_dir: tmp_dir} do
    empty_root = Path.join(tmp_dir, "empty")
    File.mkdir_p!(empty_root)
    build_existing_repo(empty_root, "flow", "https://github.com/elixir-lang/flow.git")

    Mix.Task.rerun("graft.add", ["elixir-lang/flow", "--to-manifest", "--root", empty_root])
    assert_received {:mix_shell, :info, [add_output]}
    assert add_output =~ "elixir-lang/flow"
    assert File.exists?(Path.join(empty_root, "graft.exs"))

    Mix.Task.rerun("graft.list", ["--root", empty_root])
    assert_received {:mix_shell, :info, [list_output]}
    assert list_output =~ "flow"
    assert list_output =~ "[present]"

    Mix.Task.rerun("graft.validate", ["--quick", "--root", empty_root])
    assert_received {:mix_shell, :info, [validate_output]}
    assert validate_output =~ "Graft validate --quick"
    assert validate_output =~ "flow [ok]"

    Mix.Task.rerun("graft.status", ["--root", empty_root])
    assert_received {:mix_shell, :info, [status_output]}
    assert status_output =~ "Graft workspace"
    assert status_output =~ "flow"

    Mix.Task.rerun("graft.remove", ["flow", "--root", empty_root])
    assert_received {:mix_shell, :info, [remove_output]}
    assert remove_output =~ "Graft remove (applied)"
    assert File.dir?(Path.join(empty_root, "flow"))

    {:ok, manifest} = Graft.Manifest.load(empty_root)
    assert manifest.siblings == []
  end

  test "lock rejection — link.on exits non-zero when workspace is held",
       %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".graft"))
    File.write!(Lock.lock_path(tmp_dir), "held\n")

    assert catch_exit(Mix.Task.rerun("graft.link.on", ["req_llm", "--root", tmp_dir])) ==
             {:shutdown, 1}

    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "Workspace already locked"
  end

  test "lock rejection (JSON) — kind is :workspace_locked on stdout",
       %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".graft"))
    File.write!(Lock.lock_path(tmp_dir), "held\n")

    assert catch_exit(Mix.Task.rerun("graft.link.on", ["req_llm", "--json", "--root", tmp_dir])) ==
             {:shutdown, 1}

    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["error"]["kind"] == "workspace_locked"
  end

  ## ─── Fixture ────────────────────────────────────────────────────────

  defp build_fixture(tmp_dir) do
    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        %{name: :req_llm, path: "req_llm"},
        %{name: :jido_ai, path: "jido_ai"}
      ]
    }
    """)

    File.mkdir_p!(Path.join(tmp_dir, "req_llm"))

    File.write!(Path.join([tmp_dir, "req_llm", "mix.exs"]), """
    defmodule ReqLlm.MixProject do
      use Mix.Project
      def project, do: [app: :req_llm, version: "0.1.0", deps: deps()]
      defp deps, do: []
    end
    """)

    File.mkdir_p!(Path.join(tmp_dir, "jido_ai"))

    File.write!(Path.join([tmp_dir, "jido_ai", "mix.exs"]), """
    defmodule JidoAi.MixProject do
      use Mix.Project
      def project, do: [app: :jido_ai, version: "0.1.0", deps: deps()]
      defp deps, do: [{:req_llm, "~> 1.0"}]
    end
    """)
  end

  defp build_existing_repo(root, name, origin) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    System.cmd("git", ["init", dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", dir, "remote", "add", "origin", origin], stderr_to_stdout: true)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project, do: [app: #{inspect(String.to_atom(name))}, version: "0.1.0", deps: []]
    end
    """)
  end
end
