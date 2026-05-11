# Uses Mix.Shell.Process + ExUnit.CaptureIO.
# These leak/interfere under async execution due to group-leader
# and mailbox interactions across concurrent Mix-task tests.
defmodule Mix.Tasks.Graft.Link.OffTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Graft.Link.Off, as: Task
  import Graft.Link.Off.Fixtures

  @moduletag :tmp_dir

  describe "execute/1 — dry-run" do
    test "renders restoration plan (text)", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--root", tmp_dir])

      assert output =~ "Graft link.off (dry-run)"
      assert output =~ "Targets: req_llm"
      assert output =~ "Affected repos: 1"
      assert output =~ "Restorations: 1"
      assert output =~ "jido_ai ← req_llm"
      assert output =~ ~s|from: {:req_llm, path: "../req_llm"}|
      assert output =~ ~s|to:   {:req_llm, "~> 1.0"}|
    end

    test "JSON dry-run is deterministic", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other, "~> 1.0"}]}
      ])

      apply_link_combined(tmp_dir, [:req_llm, :other])

      assert {:ok, o1} =
               Task.execute(["req_llm", "other", "--dry-run", "--json", "--root", tmp_dir])

      assert {:ok, o2} =
               Task.execute(["other", "req_llm", "--dry-run", "--json", "--root", tmp_dir])

      d1 = Jason.decode!(o1) |> Map.delete("generated_at")
      d2 = Jason.decode!(o2) |> Map.delete("generated_at")
      assert d1 == d2
      assert d1["operation"] == "link_off"
      assert d1["dry_run"] == true
      assert d1["target_apps"] == ["other", "req_llm"]
    end
  end

  describe "execute/1 — apply" do
    test "applies restoration, prunes state (text)", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other, "~> 1.0"}]}
      ])

      apply_link_combined(tmp_dir, [:req_llm, :other])

      assert {:ok, output} = Task.execute(["req_llm", "--root", tmp_dir])

      assert output =~ "Graft link.off (applied)"
      assert output =~ "Restored: 1"
      assert output =~ "Remaining state entries: 1"
      assert output =~ "Remaining linked apps: other"
    end

    test "deletes state.json when last entry is removed", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      assert {:ok, output} =
               Task.execute(["req_llm", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["operation"] == "link_off"
      assert decoded["dry_run"] == false
      assert decoded["state_deleted"] == true
      assert decoded["remaining_entries"] == 0
      refute File.exists?(Path.join([tmp_dir, ".graft", "state.json"]))
    end

    test "missing state file returns off_state_missing", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:error, output, :stdout} =
               Task.execute(["req_llm", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "off_state_missing"
    end
  end

  describe "execute/1 — argument errors" do
    test "no targets" do
      assert {:error, msg, :stderr} = Task.execute(["--dry-run"])
      assert msg =~ "at least one target app is required"
    end
  end

  describe "run/1 — Mix shell wiring" do
    setup do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous) end)
      :ok
    end

    test "apply mode emits applied summary on info", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:foo])

      Mix.Tasks.Graft.Link.Off.run(["foo", "--root", tmp_dir])

      assert_receive {:mix_shell, :info, [output]}, 500
      assert output =~ "Graft link.off (applied)"
    end

    test "missing state.json exits non-zero", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [{:foo, []}])

      assert catch_exit(Mix.Tasks.Graft.Link.Off.run(["foo", "--root", tmp_dir])) ==
               {:shutdown, 1}
    end
  end
end
