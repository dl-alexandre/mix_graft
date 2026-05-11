defmodule Graft.Link.RunnerHardeningTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Lock, State, Workspace}
  alias Graft.Link.{Plan, Runner}

  @moduletag :tmp_dir

  ## ─── Interrupted state persistence (no partial state.json) ──────────

  describe "interrupted state persistence" do
    test "no partial state.json remains after rollback", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      seed_readonly_state(tmp_dir)
      readonly_path = State.state_path(tmp_dir)
      readonly_bytes = File.read!(readonly_path)

      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)

      # The seed file is unchanged (still our empty bootstrap), and no
      # half-written sibling files exist.
      assert File.read!(readonly_path) == readonly_bytes
      refute File.exists?(readonly_path <> ".graft.tmp")
    end

    test "rerunning after a state-persist failure succeeds cleanly",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      seed_readonly_state(tmp_dir)
      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)

      # Restore writability; same plan should now apply cleanly.
      File.chmod!(State.state_path(tmp_dir), 0o644)

      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, plan2} = Plan.build(ws2, [:req_llm])
      assert {:ok, _result} = Runner.run(plan2)

      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~
               ~s|path: "../req_llm"|
    end
  end

  ## ─── Temp file cleanup ──────────────────────────────────────────────

  describe "temp file cleanup" do
    test "stray .graft.tmp from a prior crash is overwritten on success",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      stray_tmp = Path.join([tmp_dir, "jido_ai", "mix.exs.graft.tmp"])
      File.write!(stray_tmp, "garbage from a prior crash")

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      assert {:ok, _} = Runner.run(plan)

      # After a successful run no .graft.tmp survives.
      refute File.exists?(stray_tmp)
    end
  end

  ## ─── Corrupt existing state ─────────────────────────────────────────

  describe "corrupt existing state" do
    test "malformed JSON refuses mutation; mix.exs untouched",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      original = File.read!(mix_exs)

      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(State.state_path(tmp_dir), "{not json")

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:error, %Error{kind: :corrupt_state, details: %{cause: :state_invalid_json}}} =
               Runner.run(plan)

      assert File.read!(mix_exs) == original
    end

    test "unsupported version refuses mutation", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      original = File.read!(mix_exs)

      write_state(tmp_dir, %{
        "version" => 999,
        "workspace_root" => tmp_dir,
        "generated_at" => "2024-01-01T00:00:00Z",
        "entries" => []
      })

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:error, %Error{kind: :corrupt_state, details: %{cause: :state_unsupported_version}}} =
               Runner.run(plan)

      assert File.read!(mix_exs) == original
    end

    test "unknown atom payload refuses mutation", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      original = File.read!(mix_exs)

      garbage = "totally_unknown_atom_#{:erlang.unique_integer([:positive])}"

      write_state(tmp_dir, %{
        "version" => 1,
        "workspace_root" => tmp_dir,
        "generated_at" => "2024-01-01T00:00:00Z",
        "entries" => [
          %{
            "repo" => garbage,
            "repo_path" => Path.join(tmp_dir, garbage),
            "target_app" => garbage,
            "mix_exs_path" => Path.join([tmp_dir, garbage, "mix.exs"]),
            "mix_exs_before_hash" => String.duplicate("0", 64),
            "mix_exs_after_hash" => String.duplicate("1", 64),
            "preimage" => "{:foo, \"~> 1.0\"}",
            "replacement" => "{:foo, path: \"../foo\"}",
            "operation" => "link_on"
          }
        ]
      })

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:error, %Error{kind: :corrupt_state, details: %{cause: :state_unknown_atom}}} =
               Runner.run(plan)

      assert File.read!(mix_exs) == original
    end

    test "missing required field refuses mutation", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      mix_exs = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      original = File.read!(mix_exs)

      write_state(tmp_dir, %{
        "version" => 1,
        "workspace_root" => tmp_dir,
        "entries" => []
      })

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:error, %Error{kind: :corrupt_state, details: %{cause: :state_invalid_field}}} =
               Runner.run(plan)

      assert File.read!(mix_exs) == original
    end
  end

  ## ─── Double-apply idempotency ───────────────────────────────────────

  describe "double-apply idempotency" do
    test "second link.on(req_llm) is a deterministic byte-identical no-op",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, plan1} = Plan.build(ws1, [:req_llm])
      assert {:ok, _} = Runner.run(plan1)

      mix_exs_path = Path.join([tmp_dir, "jido_ai", "mix.exs"])
      mix_exs_after_first = File.read!(mix_exs_path)
      state_after_first = File.read!(State.state_path(tmp_dir))

      # Second invocation.
      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, plan2} = Plan.build(ws2, [:req_llm])
      assert Enum.all?(plan2.changes, &(&1.changed? == false))
      assert {:ok, _} = Runner.run(plan2)

      assert File.read!(mix_exs_path) == mix_exs_after_first
      assert File.read!(State.state_path(tmp_dir)) == state_after_first

      {:ok, state} = State.load(tmp_dir)
      keys = Enum.map(state.entries, &{&1.repo, &1.target_app})
      assert keys == [{:jido_ai, :req_llm}]
    end
  end

  ## ─── Concurrent invocation protection ───────────────────────────────

  describe "concurrent invocation protection" do
    test "second invocation while first holds the lock fails fast",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      # Manually hold the workspace lock.
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(Lock.lock_path(tmp_dir), "held\n")

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      assert {:error, %Error{kind: :workspace_locked}} = Runner.run(plan)

      # mix.exs untouched (no mutation happened).
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~ ~s|"~> 1.0"|
    end

    test "lock is released after success and a subsequent run can acquire it",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      assert {:ok, _} = Runner.run(plan)

      refute File.exists?(Lock.lock_path(tmp_dir))

      # And a follow-up run still acquires cleanly.
      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      {:ok, plan2} = Plan.build(ws2, [:req_llm])
      assert {:ok, _} = Runner.run(plan2)
    end

    test "lock is released even after a failed/rolled-back run",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])
      seed_readonly_state(tmp_dir)

      assert {:error, %Error{kind: :runner_state_persist_failed}} = Runner.run(plan)
      refute File.exists?(Lock.lock_path(tmp_dir))
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

  defp seed_readonly_state(tmp_dir) do
    dir = Path.join(tmp_dir, ".graft")
    File.mkdir_p!(dir)

    contents =
      Jason.encode!(%{
        "version" => 1,
        "workspace_root" => tmp_dir,
        "generated_at" => "2024-01-01T00:00:00Z",
        "entries" => []
      }) <> "\n"

    path = State.state_path(tmp_dir)
    File.write!(path, contents)
    File.chmod!(path, 0o400)
  end

  defp write_state(tmp_dir, payload) do
    File.mkdir_p!(Path.join(tmp_dir, ".graft"))
    File.write!(State.state_path(tmp_dir), Jason.encode!(payload))
  end
end
