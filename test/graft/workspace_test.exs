defmodule Graft.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.{Repo, Dependency}

  @moduletag :tmp_dir

  describe "snapshot/1 — manifest errors propagate" do
    test "missing manifest returns the manifest error", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{kind: :manifest_not_found}} = Workspace.snapshot(tmp_dir)
    end
  end

  describe "snapshot/1 — repo materialization" do
    test "marks a present sibling with a mix.exs as exists? + has_mix_exs?", %{tmp_dir: tmp_dir} do
      sibling_dir = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(sibling_dir)
      File.write!(Path.join(sibling_dir, "mix.exs"), trivial_mix_exs("Alpha", :alpha))

      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{repos: [repo], deps: deps}} = Workspace.snapshot(tmp_dir)

      assert %Repo{
               name: :alpha,
               path: "alpha",
               exists?: true,
               has_mix_exs?: true
             } = repo

      assert repo.absolute_path == Path.expand(sibling_dir)
      assert deps == []
    end

    test "marks a missing sibling directory with exists?: false", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, [{:ghost, "ghost"}])

      assert {:ok, %Workspace{repos: [repo], deps: []}} = Workspace.snapshot(tmp_dir)
      assert %Repo{name: :ghost, exists?: false, has_mix_exs?: false} = repo
    end

    test "marks a sibling dir with no mix.exs as has_mix_exs?: false", %{tmp_dir: tmp_dir} do
      sibling_dir = Path.join(tmp_dir, "no_mix")
      File.mkdir_p!(sibling_dir)
      write_manifest(tmp_dir, [{:no_mix, "no_mix"}])

      assert {:ok, %Workspace{repos: [repo], deps: []}} = Workspace.snapshot(tmp_dir)
      assert %Repo{name: :no_mix, exists?: true, has_mix_exs?: false} = repo
    end
  end

  describe "snapshot/1 — dep parsing" do
    test "parses a normal hex dep", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [{:foo, ~s|"~> 1.0"|}])
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: [dep]}} = Workspace.snapshot(tmp_dir)
      assert %Dependency{repo: :alpha, app: :foo, source: :hex} = dep
      assert dep.raw =~ ":foo"
      assert dep.raw =~ "~> 1.0"
    end

    test "parses a hex dep with extra opts (only:)", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [
        {:credo, ~s|"~> 1.7"|, "only: [:dev, :test], runtime: false"}
      ])

      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: [dep]}} = Workspace.snapshot(tmp_dir)
      assert %Dependency{app: :credo, source: :hex} = dep
    end

    test "parses a path dep", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [{:foo, nil, ~s|path: "../foo"|}])
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: [dep]}} = Workspace.snapshot(tmp_dir)
      assert %Dependency{app: :foo, source: :path} = dep
      assert dep.raw =~ "path:"
    end

    test "parses a path dep declared in a 2-tuple (kw-list value)", %{tmp_dir: tmp_dir} do
      # {:foo, path: "../foo"} — Elixir keyword sugar; AST is a 2-tuple whose
      # second element is a keyword list.
      build_sibling(tmp_dir, :alpha, [], extra_deps_source: ~s|{:foo, path: "../foo"}|)
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: deps}} = Workspace.snapshot(tmp_dir)
      assert Enum.any?(deps, &match?(%Dependency{app: :foo, source: :path}, &1))
    end

    test "parses a git dep", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [
        {:foo, nil, ~s|git: "https://example.com/foo.git", tag: "v1"|}
      ])

      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: [dep]}} = Workspace.snapshot(tmp_dir)
      assert %Dependency{app: :foo, source: :git} = dep
    end

    test "parses a github: shorthand as :git", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [], extra_deps_source: ~s|{:foo, github: "owner/foo"}|)
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: deps}} = Workspace.snapshot(tmp_dir)
      assert Enum.any?(deps, &match?(%Dependency{app: :foo, source: :git}, &1))
    end

    test "path: in opts overrides version → :path", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [{:foo, ~s|"~> 1.0"|, ~s|path: "../foo"|}])
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: [dep]}} = Workspace.snapshot(tmp_dir)
      assert %Dependency{app: :foo, source: :path} = dep
    end

    test "preserves an unknown dep shape with source: :unknown", %{tmp_dir: tmp_dir} do
      # 2-tuple value is a kw-list with no path/git/github keys.
      build_sibling(tmp_dir, :alpha, [], extra_deps_source: ~s|{:foo, [some_other_opt: true]}|)
      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: deps}} = Workspace.snapshot(tmp_dir)
      assert Enum.any?(deps, &match?(%Dependency{app: :foo, source: :unknown}, &1))
    end

    test "parses multiple deps in one repo", %{tmp_dir: tmp_dir} do
      build_sibling(tmp_dir, :alpha, [
        {:foo, ~s|"~> 1.0"|},
        {:bar, nil, ~s|path: "../bar"|},
        {:baz, nil, ~s|git: "https://x/y.git"|}
      ])

      write_manifest(tmp_dir, [{:alpha, "alpha"}])

      assert {:ok, %Workspace{deps: deps}} = Workspace.snapshot(tmp_dir)
      assert length(deps) == 3
      assert Enum.find(deps, &(&1.app == :foo)).source == :hex
      assert Enum.find(deps, &(&1.app == :bar)).source == :path
      assert Enum.find(deps, &(&1.app == :baz)).source == :git
    end
  end

  describe "snapshot/1 — robustness" do
    test "snapshot remains valid if a repo's mix.exs has unparsable contents",
         %{tmp_dir: tmp_dir} do
      good = Path.join(tmp_dir, "good")
      bad = Path.join(tmp_dir, "bad")
      File.mkdir_p!(good)
      File.mkdir_p!(bad)

      File.write!(
        Path.join(good, "mix.exs"),
        mix_exs_with_deps("Good", :good, [{:foo, ~s|"~> 1.0"|}])
      )

      File.write!(Path.join(bad, "mix.exs"), "this is not :valid (((( elixir")

      write_manifest(tmp_dir, [{:good, "good"}, {:bad, "bad"}])

      assert {:ok, %Workspace{repos: repos, deps: deps}} = Workspace.snapshot(tmp_dir)
      assert length(repos) == 2
      assert Enum.all?(repos, & &1.has_mix_exs?)
      # The bad repo contributes no deps; the good repo contributes one.
      assert [%Dependency{repo: :good, app: :foo}] = deps
    end

    test "snapshot remains valid if mix.exs has no recognisable deps function",
         %{tmp_dir: tmp_dir} do
      sibling = Path.join(tmp_dir, "weird")
      File.mkdir_p!(sibling)

      File.write!(Path.join(sibling, "mix.exs"), """
      defmodule Weird.MixProject do
        use Mix.Project
        def project, do: [app: :weird, version: "0.1.0"]
      end
      """)

      write_manifest(tmp_dir, [{:weird, "weird"}])

      assert {:ok, %Workspace{repos: [%Repo{has_mix_exs?: true}], deps: []}} =
               Workspace.snapshot(tmp_dir)
    end

    test "snapshot fields generated_at + root are populated", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, [])

      assert {:ok, %Workspace{root: root, generated_at: %DateTime{}}} =
               Workspace.snapshot(tmp_dir)

      assert root == Path.expand(tmp_dir)
    end

    test "with_hex_data and with_github_data return :not_implemented errors",
         %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, [])
      {:ok, snap} = Workspace.snapshot(tmp_dir)

      assert {:error, %Error{kind: :not_implemented}} = Workspace.with_hex_data(snap)
      assert {:error, %Error{kind: :not_implemented}} = Workspace.with_github_data(snap)
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp write_manifest(tmp_dir, siblings) do
    sibling_lines =
      Enum.map_join(siblings, ",\n    ", fn {name, path} ->
        ~s|%{name: #{inspect(name)}, path: #{inspect(path)}}|
      end)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        #{sibling_lines}
      ]
    }
    """)
  end

  # Build a sibling repo at `tmp_dir/<name>` with a mix.exs containing the
  # given deps. `deps` is a list of:
  #   {app, version_string}            — emits {:app, "version"}
  #   {app, version_string, opts_src}  — emits {:app, "version", opts_src}
  #   {app, nil, opts_src}             — emits {:app, opts_src}
  defp build_sibling(tmp_dir, name, deps, opts \\ []) do
    sibling = Path.join(tmp_dir, Atom.to_string(name))
    File.mkdir_p!(sibling)

    extra = Keyword.get(opts, :extra_deps_source)
    File.write!(Path.join(sibling, "mix.exs"), mix_exs_with_deps("Sib", name, deps, extra))
  end

  defp trivial_mix_exs(module, app) do
    """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: deps()]
      end
      defp deps, do: []
    end
    """
  end

  defp mix_exs_with_deps(module, app, deps, extra \\ nil) do
    rendered =
      deps
      |> Enum.map(&render_dep/1)
      |> then(fn list -> if extra, do: list ++ [extra], else: list end)
      |> Enum.join(",\n      ")

    """
    defmodule #{Macro.camelize(to_string(module))}.MixProject do
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

  defp render_dep({app, version}) when is_binary(version),
    do: "{#{inspect(app)}, #{version}}"

  defp render_dep({app, nil, opts_src}),
    do: "{#{inspect(app)}, #{opts_src}}"

  defp render_dep({app, version, opts_src}) when is_binary(version),
    do: "{#{inspect(app)}, #{version}, #{opts_src}}"
end
