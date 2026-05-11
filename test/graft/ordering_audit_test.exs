defmodule Graft.OrderingAuditTest do
  @moduledoc """
  Lock down the deterministic-ordering trust guarantees.

  Each test reorders the inputs (manifest declarations, mix.exs dep
  lists, link.on target order, state-entry insertion order) and asserts
  that the *output* ordering is the same canonical alphabetic sort. The
  goal is to prove that the public contract is "sorted at every level"
  regardless of how inputs were arranged.
  """

  use ExUnit.Case, async: true

  alias Graft.{State, Status, Workspace}
  alias Graft.Link.{Plan, Runner}
  alias Graft.Link.Off

  @moduletag :tmp_dir

  ## ─── Workspace repos sorted by name ─────────────────────────────────

  describe "workspace repos" do
    test "are sorted alphabetically regardless of manifest declaration order",
         %{tmp_dir: tmp_dir} do
      # Manifest declares siblings in reverse-alphabetic order.
      build_manifest(tmp_dir, [:zebra, :mango, :apple])
      Enum.each([:zebra, :mango, :apple], &build_repo(tmp_dir, &1, []))

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      names = Enum.map(ws.repos, & &1.name)
      assert names == [:apple, :mango, :zebra]
    end

    test "status JSON repos are sorted by name", %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:zebra, :apple, :mango])
      Enum.each([:zebra, :apple, :mango], &build_repo(tmp_dir, &1, []))

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      decoded = Jason.decode!(Status.render(ws, :json))
      names = Enum.map(decoded["repos"], & &1["name"])
      assert names == ["apple", "mango", "zebra"]
    end

    test "two snapshots from the same disk state are byte-identical (modulo timestamp)",
         %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:zebra, :mango, :apple])
      Enum.each([:zebra, :mango, :apple], &build_repo(tmp_dir, &1, []))

      {:ok, ws1} = Workspace.snapshot(tmp_dir)
      {:ok, ws2} = Workspace.snapshot(tmp_dir)
      assert %{ws1 | id: nil, generated_at: nil} == %{ws2 | id: nil, generated_at: nil}
    end
  end

  ## ─── Deps inside a repo ─────────────────────────────────────────────

  describe "workspace deps" do
    test "are globally sorted by (repo, app) regardless of mix.exs dep order",
         %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:foo, :bar])

      # foo has deps in reverse-alphabetic order in its mix.exs.
      build_repo(tmp_dir, :foo, [
        {:zeta, "~> 1.0"},
        {:mango, "~> 1.0"},
        {:alpha, "~> 1.0"}
      ])

      build_repo(tmp_dir, :bar, [
        {:omega, "~> 1.0"},
        {:beta, "~> 1.0"}
      ])

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      keys = Enum.map(ws.deps, &{&1.repo, &1.app})
      assert keys == Enum.sort_by(keys, fn {r, a} -> {Atom.to_string(r), Atom.to_string(a)} end)

      # Spot-check: bar's deps come before foo's (alphabetic on repo).
      assert keys ==
               [
                 {:bar, :beta},
                 {:bar, :omega},
                 {:foo, :alpha},
                 {:foo, :mango},
                 {:foo, :zeta}
               ]
    end
  end

  ## ─── Link plan changes ──────────────────────────────────────────────

  describe "link.on plan" do
    test "target_apps, affected_repos, and changes are alphabetic regardless of CLI order",
         %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:zeta, :alpha, :consumer_z, :consumer_a])

      build_repo(tmp_dir, :zeta, [])
      build_repo(tmp_dir, :alpha, [])
      build_repo(tmp_dir, :consumer_z, [{:zeta, "~> 1.0"}])
      build_repo(tmp_dir, :consumer_a, [{:alpha, "~> 1.0"}])

      {:ok, ws} = Workspace.snapshot(tmp_dir)

      # Caller passes targets in non-alphabetic order — output normalizes.
      {:ok, plan} = Plan.build(ws, [:zeta, :alpha])

      assert plan.target_apps == [:alpha, :zeta]
      assert plan.affected_repos == [:consumer_a, :consumer_z]

      change_keys = Enum.map(plan.changes, &{&1.repo, &1.target_app})
      assert change_keys == Enum.sort(change_keys)
    end
  end

  ## ─── State entries after merge ──────────────────────────────────────

  describe "state entries" do
    test "are sorted by (repo, target_app) after a merge across multiple link.on runs",
         %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:zeta, :alpha, :consumer_z, :consumer_a])

      build_repo(tmp_dir, :zeta, [])
      build_repo(tmp_dir, :alpha, [])
      build_repo(tmp_dir, :consumer_z, [{:zeta, "~> 1.0"}])
      build_repo(tmp_dir, :consumer_a, [{:alpha, "~> 1.0"}])

      # Run :zeta first so it lands earliest in the file, then :alpha —
      # if merge preserved insertion order we'd see [zeta, alpha].
      apply_one(tmp_dir, :zeta)
      apply_one(tmp_dir, :alpha)

      {:ok, state} = State.load(tmp_dir)

      keys = Enum.map(state.entries, &{&1.repo, &1.target_app})
      assert keys == [{:consumer_a, :alpha}, {:consumer_z, :zeta}]
    end
  end

  ## ─── Off plan restorations ──────────────────────────────────────────

  describe "link.off plan" do
    test "restorations and affected_repos are alphabetic regardless of CLI target order",
         %{tmp_dir: tmp_dir} do
      build_manifest(tmp_dir, [:zeta, :alpha, :consumer_z, :consumer_a])

      build_repo(tmp_dir, :zeta, [])
      build_repo(tmp_dir, :alpha, [])
      build_repo(tmp_dir, :consumer_z, [{:zeta, "~> 1.0"}])
      build_repo(tmp_dir, :consumer_a, [{:alpha, "~> 1.0"}])

      apply_one(tmp_dir, :zeta)
      apply_one(tmp_dir, :alpha)

      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, state} = State.load(tmp_dir)

      {:ok, plan_zeta_first} = Off.Plan.build(ws, state, [:zeta, :alpha])
      {:ok, plan_alpha_first} = Off.Plan.build(ws, state, [:alpha, :zeta])

      keys_zf = Enum.map(plan_zeta_first.restorations, &{&1.repo, &1.target_app})
      keys_af = Enum.map(plan_alpha_first.restorations, &{&1.repo, &1.target_app})

      assert keys_zf == keys_af
      assert keys_zf == [{:consumer_a, :alpha}, {:consumer_z, :zeta}]
      assert plan_zeta_first.affected_repos == [:consumer_a, :consumer_z]
      assert plan_zeta_first.target_apps == [:alpha, :zeta]
    end
  end

  ## ─── Fixtures ───────────────────────────────────────────────────────

  defp build_manifest(tmp_dir, names) do
    rendered =
      Enum.map_join(names, ",\n    ", fn n ->
        ~s|%{name: #{inspect(n)}, path: #{inspect(Atom.to_string(n))}}|
      end)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        #{rendered}
      ]
    }
    """)
  end

  defp build_repo(tmp_dir, app, deps) do
    sibling_dir = Path.join(tmp_dir, Atom.to_string(app))
    File.mkdir_p!(sibling_dir)

    rendered =
      Enum.map_join(deps, ",\n      ", fn {dep_app, version} ->
        ~s|{#{inspect(dep_app)}, #{inspect(version)}}|
      end)

    File.write!(Path.join(sibling_dir, "mix.exs"), """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project
      def project, do: [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      defp deps, do: [#{rendered}]
    end
    """)
  end

  defp apply_one(tmp_dir, target) do
    {:ok, ws} = Workspace.snapshot(tmp_dir)
    {:ok, plan} = Plan.build(ws, [target])
    {:ok, _} = Runner.run(plan)
    :ok
  end
end
