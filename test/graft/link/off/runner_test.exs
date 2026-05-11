defmodule Graft.Link.Off.RunnerTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, State, Workspace}
  alias Graft.Link.Off.{Plan, Runner}
  alias Graft.Link.Off.Runner.Result
  import Graft.Link.Off.Fixtures

  @moduletag :tmp_dir

  describe "run/1 — successful restore" do
    test "restores byte-identical preimage and prunes state entry",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other_lib, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other_lib, "~> 0.5"}]}
      ])

      jido_ai_mix = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      jido_chat_mix = Path.join([tmp_dir, "jido_chat", "mix.exs"])
      jido_chat_post_link_marker = ~s|path: "../other_lib"|

      apply_link_combined(tmp_dir, [:req_llm, :other_lib])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      assert {:ok, %Result{} = result} = Runner.run(plan)

      # jido_ai reverted; jido_chat (still linked to other_lib) untouched.
      assert File.read!(jido_ai_mix) =~ ~s|{:req_llm, "~> 1.0"}|
      refute File.read!(jido_ai_mix) =~ ~s|path: "../req_llm"|
      assert File.read!(jido_chat_mix) =~ jido_chat_post_link_marker

      assert length(result.restored) == 1
      assert result.remaining_entries == 1
      assert result.remaining_target_apps == [:other_lib]
      refute result.state_deleted?

      # State pruned to only :other_lib entry.
      {:ok, new_state} = State.load(tmp_dir)
      assert length(new_state.entries) == 1
      assert hd(new_state.entries).target_app == :other_lib
    end

    test "byte-identical restore back to pre-link contents when only target",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      pre_link = File.read!(mix_exs)

      apply_link(tmp_dir, [:req_llm])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      assert {:ok, result} = Runner.run(plan)

      assert File.read!(mix_exs) == pre_link
      assert result.state_deleted?
      refute File.exists?(State.state_path(tmp_dir))
    end
  end

  describe "run/1 — hash mismatch" do
    test "aborts before mutation if file changed since link.on",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      tampered = File.read!(mix_exs) <> "\n# manual edit\n"
      File.write!(mix_exs, tampered)

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      assert {:error, %Error{kind: :off_hash_mismatch, details: %{phase: :before_restore}}} =
               Runner.run(plan)

      # File untouched.
      assert File.read!(mix_exs) == tampered
      # State untouched.
      {:ok, after_state} = State.load(tmp_dir)
      assert after_state.entries == state.entries
    end

    test "rolls back prior restores when a later one mismatches",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other_lib, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other_lib, "~> 1.0"}]}
      ])

      apply_link_combined(tmp_dir, [:req_llm, :other_lib])

      jido_ai_mix = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      jido_chat_mix = Path.join([tmp_dir, "jido_chat", "mix.exs"])

      ai_post_link = File.read!(jido_ai_mix)
      chat_post_link = File.read!(jido_chat_mix)

      # Tamper jido_chat so its restoration fails. jido_ai should be
      # restored first (alphabetic), then jido_chat fails → rollback.
      File.write!(jido_chat_mix, chat_post_link <> "\n# tamper\n")

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm, :other_lib])

      assert {:error, %Error{kind: :off_hash_mismatch}} = Runner.run(plan)

      # jido_ai rolled back to its post-link bytes.
      assert File.read!(jido_ai_mix) == ai_post_link

      # jido_chat untouched.
      assert File.read!(jido_chat_mix) == chat_post_link <> "\n# tamper\n"

      # State unchanged on disk.
      {:ok, after_state} = State.load(tmp_dir)
      assert length(after_state.entries) == length(state.entries)
    end
  end

  describe "run/1 — state update failure" do
    test "rolls back all restores if state update fails", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other, "~> 1.0"}]}
      ])

      apply_link_combined(tmp_dir, [:req_llm, :other])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      post_link = File.read!(mix_exs)

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      # Restore only :req_llm so state.json must be re-saved (not deleted).
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      # Make state.json unwritable by replacing the file with a
      # directory — lock can still be acquired (`.graft` is a real
      # dir), restoration completes, then state save fails with
      # `:eisdir` and the runner rolls back the restored mix.exs.
      state_path = Path.join([tmp_dir, ".graft", "state.json"])
      File.rm!(state_path)
      File.mkdir_p!(state_path)

      assert {:error, %Error{kind: :off_state_update_failed}} = Runner.run(plan)

      # mix.exs rolled back to post-link contents.
      assert File.read!(mix_exs) == post_link
    end
  end
end
