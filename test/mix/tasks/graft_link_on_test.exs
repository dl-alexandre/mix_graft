defmodule Mix.Tasks.Graft.Link.OnTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Graft.Link.On, as: Task

  @moduletag :tmp_dir

  describe "execute/1 — dry-run text" do
    test "renders header + change blocks for a populated workspace",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--root", tmp_dir])

      assert output =~ "Graft link.on (dry-run)"
      assert output =~ "Targets: req_llm"
      assert output =~ "Affected repos: 1"
      assert output =~ "Changes: 1"
      assert output =~ "jido_ai → req_llm"
      assert output =~ ~s|before: {:req_llm, "~> 1.0"}|
      assert output =~ ~s|after:  {:req_llm, path: "../req_llm"}|
      assert output =~ "changed: yes"
    end
  end

  describe "execute/1 — dry-run JSON" do
    test "produces a parseable, deterministic JSON document",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)

      assert decoded["operation"] == "link_on"
      assert decoded["dry_run"] == true
      assert decoded["target_apps"] == ["req_llm"]
      assert decoded["affected_repos"] == ["jido_ai", "jido_chat"]
      assert length(decoded["changes"]) == 2
      assert is_list(decoded["warnings"])

      [c1, c2] = decoded["changes"]
      assert c1["repo"] in ["jido_ai", "jido_chat"]
      assert c1["target_app"] == "req_llm"
      assert c1["changed"] == true
      assert c1["dependency_source_after"] =~ ~s|path: "../req_llm"|
      assert byte_size(c1["mix_exs_before_hash"]) == 64
      assert byte_size(c1["proposed_mix_exs_after_hash"]) == 64
      assert c2["repo"] in ["jido_ai", "jido_chat"]
    end
  end

  describe "execute/1 — no-op dry-run" do
    test "target with no consumers prints empty plan, not an error",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:other, [{:credo, "~> 1.7"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--root", tmp_dir])

      assert output =~ "Affected repos: 0"
      assert output =~ "Changes: 0"
      assert output =~ "(no changes required)"
    end

    test "no-op dry-run JSON has empty changes/affected lists",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:req_llm, []}])

      assert {:ok, output} =
               Task.execute(["req_llm", "--dry-run", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["affected_repos"] == []
      assert decoded["changes"] == []
    end
  end

  describe "execute/1 — multiple target apps" do
    test "expands closures for every target", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, []},
        {:consumer, [{:foo, "~> 1.0"}, {:bar, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["foo", "bar", "--dry-run", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)

      assert decoded["target_apps"] == ["bar", "foo"]
      assert decoded["affected_repos"] == ["consumer"]
      assert length(decoded["changes"]) == 2

      pairs =
        decoded["changes"]
        |> Enum.map(&{&1["repo"], &1["target_app"]})
        |> Enum.sort()

      assert pairs == [{"consumer", "bar"}, {"consumer", "foo"}]
    end
  end

  describe "execute/1 — missing target app" do
    test "rejects an unknown target with structured error (text)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])

      assert {:error, msg, :stderr} =
               Task.execute(["not_a_sibling", "--dry-run", "--root", tmp_dir])

      assert msg =~ "graft.link.on:"
      assert msg =~ "not_a_sibling"
    end

    test "rejects an unknown target with structured error (json)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])

      assert {:error, output, :stdout} =
               Task.execute(["not_a_sibling", "--dry-run", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "plan_target_not_in_workspace"
    end

    test "atoms not declared as siblings are never created (no atom exhaustion)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:foo, []}])

      # The string itself looks atom-shaped but is never coerced because
      # it isn't in the workspace's known sibling names.
      garbage = "definitely_not_an_atom_we_have_anywhere_#{:erlang.unique_integer([:positive])}"

      assert {:error, _, _} =
               Task.execute([garbage, "--dry-run", "--root", tmp_dir])

      # If atom coercion happened, this lookup would succeed; assert it
      # does not.
      assert_raise ArgumentError, fn -> String.to_existing_atom(garbage) end
    end
  end

  describe "execute/1 — determinism" do
    test "identical invocations produce identical text output",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      {:ok, o1} = Task.execute(["foo", "--dry-run", "--root", tmp_dir])
      {:ok, o2} = Task.execute(["foo", "--dry-run", "--root", tmp_dir])
      assert o1 == o2
    end

    test "JSON output is deterministic across runs (modulo generated_at)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      {:ok, o1} = Task.execute(["foo", "--dry-run", "--json", "--root", tmp_dir])
      {:ok, o2} = Task.execute(["foo", "--dry-run", "--json", "--root", tmp_dir])

      d1 = Jason.decode!(o1) |> Map.delete("generated_at")
      d2 = Jason.decode!(o2) |> Map.delete("generated_at")
      assert d1 == d2
    end

    test "target order on the CLI doesn't change rendered output",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:a, []},
        {:b, []},
        {:c, [{:a, "~> 1.0"}, {:b, "~> 1.0"}]}
      ])

      {:ok, o_ab} = Task.execute(["a", "b", "--dry-run", "--json", "--root", tmp_dir])
      {:ok, o_ba} = Task.execute(["b", "a", "--dry-run", "--json", "--root", tmp_dir])

      d1 = Jason.decode!(o_ab) |> Map.delete("generated_at")
      d2 = Jason.decode!(o_ba) |> Map.delete("generated_at")
      assert d1 == d2
    end
  end

  describe "execute/1 — mutation apply" do
    test "applies the plan and writes state.json (text)", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} = Task.execute(["req_llm", "--root", tmp_dir])

      assert output =~ "Graft link.on (applied)"
      assert output =~ "Affected repos: 1"
      assert output =~ "Applied changes: 1"
      assert output =~ "jido_ai → req_llm"
      assert output =~ "State: "

      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~
               ~s|path: "../req_llm"|

      assert File.regular?(Path.join([tmp_dir, ".graft", "state.json"]))
    end

    test "applies the plan and writes state.json (json)", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]},
        {:jido_chat, [{:req_llm, "~> 1.0"}]}
      ])

      assert {:ok, output} =
               Task.execute(["req_llm", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)

      assert decoded["operation"] == "link_on"
      assert decoded["dry_run"] == false
      assert decoded["target_apps"] == ["req_llm"]
      assert decoded["affected_repos"] == ["jido_ai", "jido_chat"]
      assert length(decoded["applied_changes"]) == 2
      assert decoded["state_path"] =~ ".graft/state.json"
      assert is_integer(decoded["duration_ms"])
    end

    test "no-op plan applies cleanly with no state file", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [{:req_llm, []}])

      assert {:ok, output} = Task.execute(["req_llm", "--root", tmp_dir])

      assert output =~ "Applied changes: 0"
      assert output =~ "(no changes applied)"
      refute File.exists?(Path.join([tmp_dir, ".graft", "state.json"]))
    end

    test "runner failure returns structured error and rolls back (json)",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      # Pre-seed a valid read-only state.json — preflight reads it
      # cleanly, mix.exs is rewritten, then the final state save fails
      # with `:eacces`, the runner rolls back, the task surfaces the
      # structured error.
      seed_readonly_state(tmp_dir)

      assert {:error, output, :stdout} =
               Task.execute(["req_llm", "--json", "--root", tmp_dir])

      decoded = Jason.decode!(output)
      assert decoded["error"]["kind"] == "runner_state_persist_failed"

      # Rollback restored the consumer.
      assert File.read!(Path.join([tmp_dir, "jido_ai", "mix.exs"])) =~
               ~s|"~> 1.0"|
    end

    test "runner error exits non-zero via run/1", %{tmp_dir: tmp_dir} do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      try do
        build_workspace(tmp_dir, [
          {:req_llm, []},
          {:jido_ai, [{:req_llm, "~> 1.0"}]}
        ])

        seed_readonly_state(tmp_dir)

        assert catch_exit(Mix.Tasks.Graft.Link.On.run(["req_llm", "--root", tmp_dir])) ==
                 {:shutdown, 1}
      after
        Mix.shell(previous)
      end
    end
  end

  describe "execute/1 — argument errors" do
    test "no target apps", %{tmp_dir: _tmp_dir} do
      assert {:error, msg, :stderr} = Task.execute(["--dry-run"])
      assert msg =~ "at least one target app is required"
    end

    test "unknown flag" do
      assert {:error, msg, :stderr} = Task.execute(["foo", "--bogus", "--dry-run"])
      assert msg =~ "graft.link.on:"
    end
  end

  describe "run/1 — Mix shell wiring" do
    setup do
      previous = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(previous) end)
      :ok
    end

    test "success writes plan to Mix.shell info", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      Mix.Tasks.Graft.Link.On.run(["foo", "--dry-run", "--root", tmp_dir])

      assert_received {:mix_shell, :info, [output]}
      assert output =~ "Graft link.on (dry-run)"
    end

    test "apply mode writes applied summary to Mix.shell info", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:foo, []},
        {:bar, [{:foo, "~> 1.0"}]}
      ])

      Mix.Tasks.Graft.Link.On.run(["foo", "--root", tmp_dir])

      assert_received {:mix_shell, :info, [output]}
      assert output =~ "Graft link.on (applied)"
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
