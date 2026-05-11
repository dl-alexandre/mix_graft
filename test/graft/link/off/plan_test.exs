defmodule Graft.Link.Off.PlanTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, State, Workspace}
  alias Graft.Link.Off.Plan
  alias Graft.Link.Off.Plan.Restoration
  import Graft.Link.Off.Fixtures

  @moduletag :tmp_dir

  describe "build/3" do
    test "filters entries by target app and emits sorted restorations",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:other_lib, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:other_lib, "~> 0.5"}]}
      ])

      # Use two consumers so each link.on run owns its own state entry —
      # link.on currently overwrites .graft/state.json on each apply,
      # so we instead apply both at once via a hand-built combined state.
      apply_link_combined(tmp_dir, [:req_llm, :other_lib])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)

      assert {:ok, %Plan{} = plan} = Plan.build(ws, state, [:req_llm])

      assert plan.operation == :link_off
      assert plan.target_apps == [:req_llm]
      assert plan.affected_repos == [:jido_ai]
      assert [%Restoration{repo: :jido_ai, target_app: :req_llm}] = plan.restorations
      assert plan.remaining_target_apps == [:other_lib]
      assert length(plan.remaining_entries) == 1
    end

    test "rejects targets that have no recorded link", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)

      assert {:error, %Error{kind: :off_target_not_in_state}} =
               Plan.build(ws, state, [:not_recorded])
    end

    test "rejects empty target list", %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [{:req_llm, []}])
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      empty_state = %State{version: State.schema_version(), workspace_root: tmp_dir, entries: []}

      assert {:error, %Error{kind: :plan_invalid_operation}} = Plan.build(ws, empty_state, [])
    end

    test "fence violation when entry repo_path is outside workspace root",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      apply_link(tmp_dir, [:req_llm])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)

      [entry] = state.entries

      tampered = %{
        state
        | entries: [
            %{entry | repo_path: "/tmp/elsewhere", mix_exs_path: "/tmp/elsewhere/mix.exs"}
          ]
      }

      assert {:error, %Error{kind: :off_workspace_violation}} =
               Plan.build(ws, tampered, [:req_llm])
    end

    test "deterministic restoration ordering across two equivalent inputs",
         %{tmp_dir: tmp_dir} do
      build_linked_workspace(tmp_dir, [
        {:foo, []},
        {:bar, []},
        {:consumer_a, [{:foo, "~> 1.0"}]},
        {:consumer_b, [{:bar, "~> 1.0"}]}
      ])

      apply_link_combined(tmp_dir, [:foo, :bar])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)

      {:ok, p1} = Plan.build(ws, state, [:bar, :foo])
      {:ok, p2} = Plan.build(ws, state, [:foo, :bar])

      assert Enum.map(p1.restorations, & &1.target_app) ==
               Enum.map(p2.restorations, & &1.target_app)

      assert p1.target_apps == p2.target_apps
      assert p1.affected_repos == p2.affected_repos
    end
  end
end
