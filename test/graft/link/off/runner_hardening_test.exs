defmodule Graft.Link.Off.RunnerHardeningTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Lock, State, Workspace}
  alias Graft.Link.Off.{Plan, Runner}
  import Graft.Link.Off.Fixtures

  @moduletag :tmp_dir

  describe "double-off idempotency" do
    test "second link.off(req_llm) returns a structured error, not a crash",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])

      # First link.off — succeeds, deletes state.
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])
      assert {:ok, _} = Runner.run(plan)

      restored_bytes = File.read!(mix_exs)
      refute File.exists?(State.state_path(tmp_dir))

      # Second link.off — state file is gone, target was already
      # restored. Plan-build refuses (no recorded link). The
      # filesystem is left exactly as the first call left it.
      assert {:error, %Error{kind: :state_io_error}} = State.load(tmp_dir)
      assert File.read!(mix_exs) == restored_bytes
    end
  end

  describe "concurrent invocation protection" do
    test "second invocation while lock is held fails fast", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      # Manually hold the lock.
      File.write!(Lock.lock_path(tmp_dir), "held\n")

      assert {:error, %Error{kind: :workspace_locked}} = Runner.run(plan)

      # State file untouched — second invocation refused before any work.
      assert {:ok, _} = State.load(tmp_dir)
    end

    test "lock is released after a successful link.off", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      assert {:ok, _} = Runner.run(plan)
      refute File.exists?(Lock.lock_path(tmp_dir))
    end
  end

  describe "interrupted state update" do
    test "rollback releases the lock", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm, :other])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)
      # Restoring only :req_llm so state.json must be re-saved (not deleted).
      {:ok, plan} = Plan.build(ws, state, [:req_llm])

      # Replace state.json with a directory so the post-restore save
      # fails with `:eisdir`. The restore that already wrote a sibling
      # mix.exs must roll back, and the lock must release.
      state_path = Path.join([tmp_dir, ".graft", "state.json"])
      File.rm!(state_path)
      File.mkdir_p!(state_path)

      assert {:error, %Error{kind: :off_state_update_failed}} = Runner.run(plan)
      refute File.exists?(Lock.lock_path(tmp_dir))
    end
  end
end
