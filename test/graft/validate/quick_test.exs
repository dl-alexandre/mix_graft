defmodule Graft.Validate.QuickTest do
  use ExUnit.Case, async: true

  alias Graft.Validate.Quick

  @moduletag :tmp_dir

  test "passes for present Elixir git siblings with matching known origin", %{tmp_dir: tmp_dir} do
    build_git_repo(tmp_dir, "alpha", "https://github.com/owner/alpha.git")

    write_manifest(tmp_dir, """
    %{
      root: ".",
      siblings: [
        %{name: :alpha, path: "alpha", origin: "https://github.com/owner/alpha.git"}
      ]
    }
    """)

    assert {:ok, result} = Quick.run(tmp_dir)
    assert result.passed?

    text = Quick.render(result, :text)
    assert text =~ "Graft validate --quick"
    assert text =~ "alpha [ok]"
    refute text =~ "mix deps.get"
    refute text =~ "mix compile"
    refute text =~ "mix test"
  end

  test "reports clear per-sibling failures", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "missing_mix"))
    File.write!(Path.join(tmp_dir, "not_a_dir"), "not a directory")

    build_git_repo(tmp_dir, "remote_mismatch", "https://github.com/other/remote_mismatch.git")

    File.mkdir_p!(Path.join(tmp_dir, "not_git"))

    File.write!(
      Path.join([tmp_dir, "not_git", "mix.exs"]),
      "defmodule NotGit.MixProject do\nend\n"
    )

    write_manifest(tmp_dir, """
    %{
      root: ".",
      siblings: [
        %{name: :missing_path, path: "missing_path"},
        %{name: :not_a_dir, path: "not_a_dir"},
        %{name: :missing_mix, path: "missing_mix"},
        %{name: :not_git, path: "not_git"},
        %{name: :remote_mismatch, path: "remote_mismatch", origin: "https://github.com/owner/remote_mismatch.git"}
      ]
    }
    """)

    assert {:ok, result} = Quick.run(tmp_dir)
    refute result.passed?

    failures_by_name =
      Map.new(result.siblings, fn sibling ->
        {sibling.name, Enum.map(sibling.failures, & &1.kind)}
      end)

    assert :path_missing in failures_by_name.missing_path
    assert :path_not_directory in failures_by_name.not_a_dir
    assert :mix_exs_missing in failures_by_name.missing_mix
    assert :git_repo_missing in failures_by_name.not_git
    assert :origin_mismatch in failures_by_name.remote_mismatch

    json = Jason.decode!(Quick.render(result, :json))
    assert json["passed"] == false
    assert Enum.any?(json["siblings"], &(&1["status"] == "failed"))
  end

  test "can limit quick validation to named siblings", %{tmp_dir: tmp_dir} do
    build_git_repo(tmp_dir, "alpha", "https://github.com/owner/alpha.git")
    File.mkdir_p!(Path.join(tmp_dir, "beta"))

    write_manifest(tmp_dir, """
    %{
      root: ".",
      siblings: [
        %{name: :alpha, path: "alpha"},
        %{name: :beta, path: "beta"}
      ]
    }
    """)

    assert {:ok, result} = Quick.run(tmp_dir, ["alpha"])
    assert result.passed?
    assert Enum.map(result.siblings, & &1.name) == [:alpha]
  end

  defp build_git_repo(root, name, origin) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    System.cmd("git", ["init", dir], stderr_to_stdout: true)
    System.cmd("git", ["-C", dir, "remote", "add", "origin", origin], stderr_to_stdout: true)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      use Mix.Project
      def project, do: [app: #{inspect(String.to_atom(name))}, version: "0.1.0", deps: []]
    end
    """)
  end

  defp write_manifest(dir, contents) do
    File.write!(Path.join(dir, "graft.exs"), contents)
  end
end
