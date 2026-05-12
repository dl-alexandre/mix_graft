defmodule Mix.Tasks.Graft.RemoveTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Graft.Remove, as: Task

  @moduletag :tmp_dir

  test "execute supports dry-run", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir)

    assert {:ok, output} = Task.execute(["alpha", "--dry-run", "--root", tmp_dir])
    assert output =~ "Graft remove (dry-run)"
    assert output =~ "alpha"

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert Enum.map(manifest.siblings, & &1.name) == [:alpha]
  end

  test "execute removes manifest entry", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir)

    assert {:ok, output} = Task.execute(["alpha", "--root", tmp_dir])
    assert output =~ "Graft remove (applied)"

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert manifest.siblings == []
  end

  test "execute routes dirty delete refusal to stderr", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir)

    assert {:error, output, :stderr} = Task.execute(["alpha", "--delete", "--root", tmp_dir])
    assert output =~ "Graft remove (refused)"
    assert output =~ "remove_dirty_repo"
  end

  test "execute routes json refusal to stdout", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir)

    assert {:error, output, :stdout} =
             Task.execute(["alpha", "--delete", "--json", "--root", tmp_dir])

    decoded = Jason.decode!(output)
    assert decoded["passed"] == false

    assert hd(decoded["outcomes"])["failures"] |> hd() |> Map.fetch!("kind") ==
             "remove_dirty_repo"
  end

  defp build_workspace(tmp_dir) do
    dir = Path.join(tmp_dir, "alpha")
    File.mkdir_p!(dir)
    System.cmd("git", ["init", dir], stderr_to_stdout: true)

    System.cmd(
      "git",
      ["-C", dir, "remote", "add", "origin", "https://github.com/owner/alpha.git"],
      stderr_to_stdout: true
    )

    File.write!(Path.join(dir, "mix.exs"), "# dirty repo\n")

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        %{name: :alpha, path: "alpha", origin: "https://github.com/owner/alpha.git"}
      ]
    }
    """)
  end
end
