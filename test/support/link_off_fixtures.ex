defmodule Graft.Link.Off.Fixtures do
  @moduledoc false

  # Builds a workspace and (optionally) applies a link.on so that
  # `.graft/state.json` exists and the consumer mix.exs files are in
  # their post-link form. Mirrors the fixture used by the on-tests.

  alias Graft.Workspace
  alias Graft.Link.{Plan, Runner}

  def build_linked_workspace(tmp_dir, sibling_specs) do
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

  def apply_link(_tmp_dir, []), do: :ok

  def apply_link(tmp_dir, target_apps) do
    # Apply one target at a time. State merging in link.on preserves
    # entries across runs, so subsequent calls accumulate state rather
    # than overwriting it. Sequential application also sidesteps the
    # per-change before-hash sensitivity in Plan when multiple targets
    # share a consumer.
    Enum.each(target_apps, fn target ->
      {:ok, ws} = Workspace.snapshot(tmp_dir)
      {:ok, plan} = Plan.build(ws, [target])
      {:ok, _result} = Runner.run(plan)
    end)

    :ok
  end

  # Back-compat alias from before link.on state merging existed. With
  # merging in place, sequential `apply_link/2` accumulates state the
  # same way the hand-built combined fixture used to.
  def apply_link_combined(tmp_dir, target_apps), do: apply_link(tmp_dir, target_apps)

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
