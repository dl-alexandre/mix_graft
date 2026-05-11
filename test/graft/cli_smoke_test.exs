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
end
