defmodule Graft.Link.RunnerTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, State, Workspace}
  alias Graft.Link.{Plan, Runner}
  alias Graft.Link.Plan.Change
  alias Graft.Link.Runner.Result

  @moduletag :tmp_dir

  ## ─── Successful transactional apply ─────────────────────────────────

  describe "run/2 — successful apply" do
    test "applies all changes and persists state.json", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:ok, %Result{} = result} = Runner.run(plan)

      # Both consumer mix.exs files now reference req_llm via path.
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~
               ~s|path: "../req_llm"|

      assert File.read!(Path.join([tmp_dir, "jido_chat", "mix.exs"])) =~
               ~s|path: "../req_llm"|

      # Result fields populated.
      assert length(result.applied_changes) == 2
      assert result.rolled_back_changes == []
      assert result.state_path == State.state_path(tmp_dir)
      assert result.duration_ms >= 0

      # State file written and parseable.
      assert File.regular?(result.state_path)
      assert {:ok, loaded} = State.load(tmp_dir)
      assert length(loaded.entries) == 2
      assert Enum.all?(loaded.entries, &(&1.target_app == :req_llm))
    end

    test "no temp files remain after a successful run", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      {:ok, _} = Runner.run(plan)

      refute File.exists?(Path.join([tmp_dir, "jido_ai", "mix.exs.graft.tmp"]))
    end
  end

  ## ─── No-op plan ─────────────────────────────────────────────────────

  describe "run/2 — no-op plan" do
    test "plan with no consumers returns success and writes no state",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:req_llm, []}])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert plan.changes == []
      assert {:ok, result} = Runner.run(plan)

      assert result.applied_changes == []
      refute File.exists?(result.state_path)
    end
  end

  ## ─── Hash mismatch aborts before mutation ──────────────────────────

  describe "run/2 — hash mismatch" do
    test "aborts and leaves the file untouched if the before-hash diverges",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      original_bytes = File.read!(mix_exs)

      # Tamper between plan and run.
      File.write!(mix_exs, original_bytes <> "\n# extra comment\n")

      assert {:error, %Error{kind: :runner_hash_mismatch, details: %{phase: :before}}} =
               Runner.run(plan)

      # File still has the user's tampered contents — we did not touch it.
      assert File.read!(mix_exs) == original_bytes <> "\n# extra comment\n"

      # No state file written.
      refute File.exists?(State.state_path(tmp_dir))
    end

    test "rolls back already-applied changes when a later change has hash mismatch",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # Snapshot original bytes.
      jido_ai_mix = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      jido_chat_mix = Path.join([tmp_dir, "jido_chat", "mix.exs"])
      jido_ai_original = File.read!(jido_ai_mix)
      jido_chat_original = File.read!(jido_chat_mix)

      # Tamper with the *second* repo only — first one is fine.
      File.write!(jido_chat_mix, jido_chat_original <> "\n#tamper\n")

      assert {:error, %Error{kind: :runner_hash_mismatch}} = Runner.run(plan)

      # Whichever repo got applied first must be rolled back to original
      # bytes. Order is sorted alphabetically, so jido_ai applies first
      # then jido_chat fails. After rollback, jido_ai should be original.
      assert File.read!(jido_ai_mix) == jido_ai_original

      # The tampered repo is left as the user wrote it (we never touched it).
      assert File.read!(jido_chat_mix) == jido_chat_original <> "\n#tamper\n"

      # No state.json (rollback path).
      refute File.exists?(State.state_path(tmp_dir))
    end
  end

  ## ─── Rollback restores byte-identical preimages ─────────────────────

  describe "run/2 — rollback fidelity" do
    test "rolled-back files are byte-identical to the originals",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      jido_ai_original = File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"]))
      jido_chat_original = File.read!(Path.join([tmp_dir, "jido_chat", "mix.exs"]))

      # Force a state-save failure mid-flow: pre-create a valid empty
      # state.json that's read-only. Lock acquires; preflight reads it
      # cleanly; mix.exs writes succeed; the final state save fails
      # with `:eacces`, triggering rollback.
      seed_readonly_state(tmp_dir)

      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)

      # Both consumers restored exactly.
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) == jido_ai_original
      assert File.read!(Path.join([tmp_dir, "jido_chat", "mix.exs"])) == jido_chat_original
    end
  end

  ## ─── State persistence failure ──────────────────────────────────────

  describe "run/2 — state persistence failure" do
    test "rolls back all writes if state.json save fails", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      original = File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"]))

      seed_readonly_state(tmp_dir)

      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)

      # Rollback restored the file.
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) == original
    end
  end

  ## ─── Workspace fence enforcement ────────────────────────────────────

  describe "run/2 — workspace fence" do
    test "refuses to mutate a change whose repo_path is outside workspace root",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      # Hand-craft a tampered plan whose change points outside the root.
      [%Change{} = c0] = plan.changes

      malicious_path =
        Path.join(System.tmp_dir!(), "outside_repo_#{:erlang.unique_integer([:positive])}")

      tampered = %{plan | changes: [%{c0 | repo_path: malicious_path}]}

      assert {:error, %Error{kind: :runner_fence_violation}} = Runner.run(tampered)

      # Original consumer untouched.
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~ ~s|"~> 1.0"|
    end
  end

  ## ─── Determinism ────────────────────────────────────────────────────

  describe "run/2 — deterministic result ordering" do
    test "applied_changes order matches plan.changes order (effective only)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      effective = Enum.filter(plan.changes, & &1.changed?)

      {:ok, result} = Runner.run(plan)

      assert Enum.map(result.applied_changes, & &1.repo) ==
               Enum.map(effective, & &1.repo)
    end
  end

  ## ─── Temp file cleanup ──────────────────────────────────────────────

  describe "run/2 — temp file cleanup" do
    test "no .graft.tmp left after rollback path", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      seed_readonly_state(tmp_dir)

      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)

      refute File.exists?(Path.join([tmp_dir, "jido_ai", "mix.exs.graft.tmp"]))
    end
  end

  ## ─── State merging across runs ──────────────────────────────────────

  describe "run/2 — state merging" do
    test "second link.on of a different target preserves the first's entry",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido, []},
        {:consumer_a, [{:req_llm, "~> 1.0"}]},
        {:consumer_b, [{:jido, "~> 1.0"}]}
      ])

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws1, [:req_llm])
      {:ok, _} = Runner.run(p1)

      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, p2} = Plan.build(ws2, [:jido])
      {:ok, _} = Runner.run(p2)

      {:ok, state} = State.load(tmp_dir)
      target_apps = state.entries |> Enum.map(& &1.target_app) |> Enum.sort()
      assert target_apps == [:jido, :req_llm]
    end

    test "re-running link.on for the same target is a deterministic no-op",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:consumer, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws1, [:req_llm])
      {:ok, _} = Runner.run(p1)

      bytes_after_first = File.read!(State.state_path(tmp_dir))
      mix_exs_after_first = File.read!(Path.join([tmp_dir, "consumer", "mix.exs"]))

      # Second run — consumer is already linked, plan has no effective
      # changes, runner skips state save entirely. State and mix.exs
      # untouched byte-for-byte.
      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, p2} = Plan.build(ws2, [:req_llm])
      assert Enum.all?(p2.changes, &(&1.changed? == false))
      {:ok, _} = Runner.run(p2)

      assert File.read!(State.state_path(tmp_dir)) == bytes_after_first
      assert File.read!(Path.join([tmp_dir, "consumer", "mix.exs"])) == mix_exs_after_first

      {:ok, state} = State.load(tmp_dir)
      assert length(state.entries) == 1
    end

    test "merge replaces entries with matching {repo, target_app} key",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido, []},
        {:consumer, [{:req_llm, "~> 1.0"}, {:jido, "~> 2.0"}]}
      ])

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws1, [:req_llm])
      {:ok, _} = Runner.run(p1)

      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, p2} = Plan.build(ws2, [:jido])
      {:ok, _} = Runner.run(p2)

      {:ok, state} = State.load(tmp_dir)
      keys = state.entries |> Enum.map(&{&1.repo, &1.target_app}) |> Enum.sort()
      assert keys == [{:consumer, :jido}, {:consumer, :req_llm}]
      assert length(state.entries) == 2
    end

    test "merged state entries are sorted deterministically",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:zeta, []},
        {:alpha, []},
        {:consumer_z, [{:zeta, "~> 1.0"}]},
        {:consumer_a, [{:alpha, "~> 1.0"}]}
      ])

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, p1} = Plan.build(ws1, [:zeta])
      {:ok, _} = Runner.run(p1)

      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, p2} = Plan.build(ws2, [:alpha])
      {:ok, _} = Runner.run(p2)

      {:ok, state} = State.load(tmp_dir)
      keys = Enum.map(state.entries, &{Atom.to_string(&1.repo), Atom.to_string(&1.target_app)})
      assert keys == Enum.sort(keys)
    end
  end

  ## ─── Fixtures ───────────────────────────────────────────────────────

  defp build_workspace(tmp_dir, sibling_specs) do
    siblings_for_manifest =
      Enum.map_join(sibling_specs, ",\n    ", fn {name, _deps} ->
        ~s|%{name: #{inspect(name)}, path: #{inspect(Atom.to_string(name))}}|
      end)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        #{siblings_for_manifest}
      ]
    }
    """)

    Enum.each(sibling_specs, fn {name, deps} ->
      sibling_dir = Path.join(tmp_dir, Atom.to_string(name))
      File.mkdir_p!(sibling_dir)
      File.write!(Path.join(sibling_dir, "mix.exs"), mix_exs_for(name, deps))
    end)
  end

  # Seed `.graft/state.json` with a valid empty state and chmod it
  # read-only, so preflight load succeeds but the final save fails
  # with :eacces — exercising the post-mutation rollback path.
  defp seed_readonly_state(tmp_dir) do
    dir = Path.join(tmp_dir, ".graft")
    path = Path.join(dir, "state.json")
    File.mkdir_p!(dir)

    contents =
      Jason.encode!(%{
        "version" => 1,
        "workspace_root" => tmp_dir,
        "generated_at" => "2024-01-01T00:00:00Z",
        "entries" => []
      }) <> "\n"

    File.write!(path, contents)
    File.chmod!(path, 0o400)
    path
  end

  defp mix_exs_for(app, deps) do
    rendered =
      Enum.map_join(deps, ",\n      ", fn {dep_app, version} ->
        ~s|{#{inspect(dep_app)}, #{inspect(version)}}|
      end)

    """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          #{rendered}
        ]
      end
    end
    """
  end
end
