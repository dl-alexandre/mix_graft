defmodule Graft.DriftTest do
  use ExUnit.Case, async: true

  alias Graft.Workspace
  alias Graft.Drift

  defp tmp_dir do
    rand =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    Path.join(System.tmp_dir!(), "drift_test_#{rand}")
  end

  defp managed_repo(name, abs) do
    %Workspace.Repo{
      name: name,
      path: Atom.to_string(name),
      absolute_path: abs,
      exists?: true,
      has_mix_exs?: true,
      ownership: :managed
    }
  end

  defp external_repo(name, abs) do
    %Workspace.Repo{
      name: name,
      path: Atom.to_string(name),
      absolute_path: abs,
      exists?: true,
      has_mix_exs?: true,
      ownership: :external
    }
  end

  describe "check/2 — managed repos" do
    test "reports :none when symlink is correct" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()
      File.mkdir_p!(graft_root)
      File.ln_s!(source, Path.join(graft_root, "repo"))

      repo = managed_repo(:repo, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :none
      assert Drift.ok?(drift)
      refute Drift.drifted?(drift)
      assert Drift.summary(drift) == "repo: no drift"
    end

    test "reports :missing when symlink is absent" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = managed_repo(:repo, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :missing
      refute Drift.ok?(drift)
      assert Drift.drifted?(drift)
      assert Drift.summary(drift) =~ "missing"
    end

    test "reports :changed when symlink points elsewhere" do
      source_a = tmp_dir()
      source_b = tmp_dir()
      File.mkdir_p!(source_a)
      File.mkdir_p!(source_b)
      graft_root = tmp_dir()
      File.mkdir_p!(graft_root)
      File.ln_s!(source_b, Path.join(graft_root, "repo"))

      repo = managed_repo(:repo, source_a)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :changed
      refute Drift.ok?(drift)
      assert Drift.summary(drift) =~ "changed"
    end

    test "reports :changed when path is a real directory" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()
      File.mkdir_p!(graft_root)
      File.mkdir_p!(Path.join(graft_root, "repo"))

      repo = managed_repo(:repo, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :changed
      assert drift.details.kind == :not_a_symlink
    end

    test "reports :changed on read error" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()
      # Create a regular file that is not a symlink — read_link returns einval
      File.mkdir_p!(graft_root)
      File.write!(Path.join(graft_root, "repo"), "x")

      repo = managed_repo(:repo, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :changed
    end
  end

  describe "check/2 — external repos" do
    test "reports :none when source exists" do
      source = tmp_dir()
      File.mkdir_p!(source)
      graft_root = tmp_dir()

      repo = external_repo(:ext, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :none
      assert Drift.ok?(drift)
    end

    test "reports :missing when source is gone" do
      source = tmp_dir()
      File.rm_rf!(source)
      graft_root = tmp_dir()

      repo = external_repo(:ext, source)
      drift = Drift.check(repo, graft_root)

      assert drift.classification == :missing
      refute Drift.ok?(drift)
      assert Drift.summary(drift) =~ "missing"
    end
  end
end
