defmodule Graft.RemoveTest do
  use ExUnit.Case, async: true

  alias Graft.Remove

  @moduletag :tmp_dir

  test "dry-run reports planned manifest removal without changing files", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir, clean?: true)

    assert {:ok, result} = Remove.remove(["alpha"], tmp_dir, dry_run: true)
    refute result.applied?
    assert result.passed?
    assert File.exists?(Path.join(tmp_dir, "graft.exs"))
    assert File.dir?(Path.join(tmp_dir, "alpha"))

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert Enum.map(manifest.siblings, & &1.name) == [:alpha]
  end

  test "removes from manifest and leaves filesystem by default", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir, clean?: true)

    assert {:ok, result} = Remove.remove(["alpha"], tmp_dir)
    assert result.applied?
    assert File.dir?(Path.join(tmp_dir, "alpha"))

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert manifest.siblings == []
  end

  test "deletes filesystem only when delete option is explicit", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir, clean?: true)

    assert {:ok, result} = Remove.remove(["alpha"], tmp_dir, delete: true)
    assert result.applied?
    refute File.exists?(Path.join(tmp_dir, "alpha"))

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert manifest.siblings == []
  end

  test "refuses to delete dirty git repos unless forced", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir, clean?: false)

    assert {:error, result} = Remove.remove(["alpha"], tmp_dir, delete: true)
    refute result.passed?
    assert File.dir?(Path.join(tmp_dir, "alpha"))

    [outcome] = result.outcomes
    assert :remove_dirty_repo in Enum.map(outcome.failures, & &1.kind)

    {:ok, manifest} = Graft.Manifest.load(tmp_dir)
    assert Enum.map(manifest.siblings, & &1.name) == [:alpha]

    assert {:ok, forced} = Remove.remove(["alpha"], tmp_dir, delete: true, force: true)
    assert forced.applied?
    refute File.exists?(Path.join(tmp_dir, "alpha"))
  end

  test "unknown sibling returns a clear error", %{tmp_dir: tmp_dir} do
    build_workspace(tmp_dir, clean?: true)

    assert {:error, %Graft.Error{kind: :remove_target_not_in_manifest, message: message}} =
             Remove.remove(["missing"], tmp_dir)

    assert message =~ "missing"
  end

  defp build_workspace(tmp_dir, opts) do
    clean? = Keyword.fetch!(opts, :clean?)

    build_git_repo(Path.join(tmp_dir, "alpha"), clean?)

    File.write!(Path.join(tmp_dir, "graft.exs"), """
    %{
      root: ".",
      siblings: [
        %{name: :alpha, path: "alpha", origin: "https://github.com/owner/alpha.git"}
      ]
    }
    """)
  end

  defp build_git_repo(dir, clean?) do
    File.mkdir_p!(dir)
    System.cmd("git", ["init", dir], stderr_to_stdout: true)

    System.cmd(
      "git",
      ["-C", dir, "remote", "add", "origin", "https://github.com/owner/alpha.git"],
      stderr_to_stdout: true
    )

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, version: "0.1.0", deps: []]
    end
    """)

    if clean? do
      System.cmd("git", ["-C", dir, "config", "user.email", "test@example.com"],
        stderr_to_stdout: true
      )

      System.cmd("git", ["-C", dir, "config", "user.name", "Test User"], stderr_to_stdout: true)
      System.cmd("git", ["-C", dir, "add", "mix.exs"], stderr_to_stdout: true)
      System.cmd("git", ["-C", dir, "commit", "-m", "init"], stderr_to_stdout: true)
    end
  end
end
