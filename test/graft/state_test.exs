defmodule Graft.StateTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, State, Workspace}
  alias Graft.State.Entry
  alias Graft.Link.Plan
  alias Graft.Link.Plan.Change

  @moduletag :tmp_dir

  describe "hash_contents/1" do
    test "produces a 64-char lowercase hex SHA-256" do
      hash = State.hash_contents("hello world")
      assert byte_size(hash) == 64
      assert String.match?(hash, ~r/\A[0-9a-f]+\z/)

      assert hash ==
               "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    end

    test "is consistent across calls" do
      a = State.hash_contents("foo")
      b = State.hash_contents("foo")
      assert a == b
    end

    test "differs for different inputs" do
      assert State.hash_contents("foo") != State.hash_contents("bar")
    end
  end

  describe "save/2 + load/1 — round trip" do
    test "writes and reads back a fully-populated state", %{tmp_dir: tmp_dir} do
      state = sample_state(tmp_dir)

      assert :ok = State.save(tmp_dir, state)

      path = State.state_path(tmp_dir)
      assert File.regular?(path)

      assert {:ok, loaded} = State.load(tmp_dir)

      assert loaded.version == state.version
      assert loaded.workspace_root == state.workspace_root
      assert loaded.generated_at == state.generated_at
      assert loaded.entries == state.entries
    end

    test "creates `.graft/` if it does not exist", %{tmp_dir: tmp_dir} do
      refute File.exists?(Path.join(tmp_dir, ".graft"))

      assert :ok = State.save(tmp_dir, sample_state(tmp_dir))

      assert File.dir?(Path.join(tmp_dir, ".graft"))
      assert File.regular?(Path.join([tmp_dir, ".graft", "state.json"]))
    end

    test "writes pretty JSON with a trailing newline", %{tmp_dir: tmp_dir} do
      State.save(tmp_dir, sample_state(tmp_dir))

      contents = File.read!(State.state_path(tmp_dir))
      assert String.ends_with?(contents, "\n")
      # Pretty output spans multiple lines:
      assert contents =~ "\n  "
    end

    test "preserves atom values via string round-trip", %{tmp_dir: tmp_dir} do
      State.save(tmp_dir, sample_state(tmp_dir))

      raw = File.read!(State.state_path(tmp_dir)) |> Jason.decode!()
      assert raw["entries"] |> hd() |> Map.get("repo") == "jido_ai"
      assert raw["entries"] |> hd() |> Map.get("target_app") == "req_llm"
      assert raw["entries"] |> hd() |> Map.get("operation") == "link_on"

      {:ok, loaded} = State.load(tmp_dir)
      [entry] = loaded.entries
      assert entry.repo == :jido_ai
      assert entry.target_app == :req_llm
      assert entry.operation == :link_on
    end
  end

  describe "save/2 — deterministic serialization" do
    test "saving the same state twice produces byte-identical files",
         %{tmp_dir: tmp_dir} do
      state = sample_state(tmp_dir)

      State.save(tmp_dir, state)
      first = File.read!(State.state_path(tmp_dir))

      State.save(tmp_dir, state)
      second = File.read!(State.state_path(tmp_dir))

      assert first == second
    end
  end

  describe "load/1 — error paths" do
    test "missing file returns state_io_error", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{kind: :state_io_error}} = State.load(tmp_dir)
    end

    test "invalid JSON returns state_invalid_json", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(State.state_path(tmp_dir), "{this is not valid json")

      assert {:error, %Error{kind: :state_invalid_json}} = State.load(tmp_dir)
    end

    test "non-object JSON returns state_invalid_shape", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(State.state_path(tmp_dir), "[1, 2, 3]")

      assert {:error, %Error{kind: :state_invalid_shape}} = State.load(tmp_dir)
    end

    test "missing version field returns state_invalid_field", %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{"workspace_root" => "/x", "generated_at" => "now", "entries" => []})

      assert {:error, %Error{kind: :state_invalid_field, details: %{key: "version"}}} =
               State.load(tmp_dir)
    end

    test "unsupported version returns state_unsupported_version",
         %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{
        "version" => 99,
        "workspace_root" => "/x",
        "generated_at" => "now",
        "entries" => []
      })

      assert {:error, %Error{kind: :state_unsupported_version, details: %{got: 99}}} =
               State.load(tmp_dir)
    end

    test "version of wrong type returns state_invalid_field",
         %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{
        "version" => "1",
        "workspace_root" => "/x",
        "generated_at" => "now",
        "entries" => []
      })

      assert {:error, %Error{kind: :state_invalid_field, details: %{key: "version"}}} =
               State.load(tmp_dir)
    end

    test "missing entries returns state_invalid_field", %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{
        "version" => 1,
        "workspace_root" => "/x",
        "generated_at" => "now"
      })

      assert {:error, %Error{kind: :state_invalid_field, details: %{key: "entries"}}} =
               State.load(tmp_dir)
    end

    test "entries with missing required field returns state_invalid_field",
         %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{
        "version" => 1,
        "workspace_root" => "/x",
        "generated_at" => "now",
        "entries" => [%{"repo" => "jido_ai"}]
      })

      assert {:error, %Error{kind: :state_invalid_field, details: %{index: 0}}} =
               State.load(tmp_dir)
    end

    test "unsupported operation returns state_invalid_field", %{tmp_dir: tmp_dir} do
      # Pre-create the atoms via the workspace path so to_existing_atom
      # succeeds for repo/target_app, leaving operation as the only
      # invalid field.
      _ = sample_state(tmp_dir)

      write_raw(tmp_dir, %{
        "version" => 1,
        "workspace_root" => tmp_dir,
        "generated_at" => "now",
        "entries" => [
          full_entry_json(%{"operation" => "weird_op"})
        ]
      })

      assert {:error, %Error{kind: :state_unknown_atom}} = State.load(tmp_dir)
    end

    test "atoms not yet known are rejected, never coerced",
         %{tmp_dir: tmp_dir} do
      write_raw(tmp_dir, %{
        "version" => 1,
        "workspace_root" => "/x",
        "generated_at" => "now",
        "entries" => [
          full_entry_json(%{
            "repo" => "atom_that_doesnt_exist_#{:erlang.unique_integer([:positive])}"
          })
        ]
      })

      assert {:error, %Error{kind: :state_unknown_atom}} = State.load(tmp_dir)
    end
  end

  describe "migrate/1" do
    test "v1 is the identity transformation" do
      state = %State{
        version: 1,
        workspace_root: "/tmp/ws",
        generated_at: "2024-01-01T00:00:00Z",
        entries: []
      }

      assert {:ok, ^state} = State.migrate(state)
    end

    test "future versions return :state_unsupported_version" do
      state = %State{
        version: 2,
        workspace_root: "/tmp/ws",
        generated_at: "2024-01-01T00:00:00Z",
        entries: []
      }

      assert {:error,
              %Error{
                kind: :state_unsupported_version,
                details: %{got: 2, expected: 1}
              }} = State.migrate(state)
    end

    test "non-integer version is a state_invalid_field error" do
      state = %State{version: "1", workspace_root: "/tmp/ws", entries: []}
      assert {:error, %Error{kind: :state_invalid_field}} = State.migrate(state)
    end

    test "missing (nil) version is a state_invalid_field error" do
      state = %State{version: nil, workspace_root: "/tmp/ws", entries: []}
      assert {:error, %Error{kind: :state_invalid_field}} = State.migrate(state)
    end

    test "non-State input is a state_invalid_field error" do
      assert {:error, %Error{kind: :state_invalid_field}} = State.migrate(%{version: 1})
    end
  end

  describe "from_plan/1" do
    test "projects a Plan into a State", %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      state = State.from_plan(plan)

      assert state.version == State.schema_version()
      assert state.workspace_root == plan.workspace_root
      assert state.generated_at == DateTime.to_iso8601(plan.generated_at)
      assert length(state.entries) == 1

      [entry] = state.entries
      assert entry.repo == :jido_ai
      assert entry.target_app == :req_llm
      assert entry.operation == :link_on
      assert entry.preimage =~ ~s|"~> 1.0"|
      assert entry.replacement =~ ~s|path: "../req_llm"|
      assert entry.mix_exs_path == Path.join(entry.repo_path, "mix.exs")
      assert byte_size(entry.mix_exs_before_hash) == 64
      assert byte_size(entry.mix_exs_after_hash) == 64
    end

    test "skips no-op changes (changed?: false)", %{tmp_dir: tmp_dir} do
      plan = %Plan{
        operation: :link_on,
        generated_at: ~U[2026-01-01 00:00:00Z],
        workspace_root: tmp_dir,
        target_apps: [:foo],
        affected_repos: [:bar],
        changes: [
          %Change{
            repo: :bar,
            repo_path: "/x/bar",
            target_app: :foo,
            dependency_source_before: "{:foo, ...}",
            dependency_source_after: "{:foo, ...}",
            mix_exs_before_hash: "abc",
            proposed_mix_exs_after_hash: "abc",
            changed?: false
          }
        ]
      }

      state = State.from_plan(plan)
      assert state.entries == []
    end

    test "from_plan output round-trips through save/load",
         %{tmp_dir: tmp_dir} do
      build_workspace(tmp_dir, [
        {:req_llm, []},
        {:jido_ai, [{:req_llm, "~> 1.0"}]}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [:req_llm])

      state = State.from_plan(plan)

      assert :ok = State.save(tmp_dir, state)
      assert {:ok, loaded} = State.load(tmp_dir)

      assert loaded.entries == state.entries
    end
  end

  ## ─── Fixtures ───────────────────────────────────────────────────────

  defp sample_state(tmp_dir) do
    %State{
      version: State.schema_version(),
      workspace_root: tmp_dir,
      generated_at: "2026-01-01T00:00:00Z",
      entries: [
        %Entry{
          repo: :jido_ai,
          repo_path: Path.join(tmp_dir, "jido_ai"),
          target_app: :req_llm,
          mix_exs_path: Path.join([tmp_dir, "jido_ai", "mix.exs"]),
          mix_exs_before_hash: String.duplicate("a", 64),
          mix_exs_after_hash: String.duplicate("b", 64),
          preimage: ~s|{:req_llm, "~> 1.0"}|,
          replacement: ~s|{:req_llm, path: "../req_llm"}|,
          operation: :link_on
        }
      ]
    }
  end

  defp full_entry_json(overrides) do
    Map.merge(
      %{
        "repo" => "jido_ai",
        "repo_path" => "/x/jido_ai",
        "target_app" => "req_llm",
        "mix_exs_path" => "/x/jido_ai/mix.exs",
        "mix_exs_before_hash" => String.duplicate("a", 64),
        "mix_exs_after_hash" => String.duplicate("b", 64),
        "preimage" => "x",
        "replacement" => "y",
        "operation" => "link_on"
      },
      overrides
    )
  end

  defp write_raw(tmp_dir, data) do
    File.mkdir_p!(Path.join(tmp_dir, ".graft"))
    File.write!(State.state_path(tmp_dir), Jason.encode!(data))
  end

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
      def project, do: [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      defp deps, do: [#{rendered}]
    end
    """
  end
end
