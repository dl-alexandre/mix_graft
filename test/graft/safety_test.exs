defmodule Graft.SafetyTest do
  use ExUnit.Case, async: true

  alias Graft.Safety

  describe "allowed_root?/1" do
    test "accepts paths inside temp directory" do
      tmp = System.tmp_dir!()
      sub = Path.join(tmp, "safety_test_#{:erlang.unique_integer([:positive])}")
      assert Safety.allowed_root?(sub) == :ok
    end

    test "accepts paths inside current working directory" do
      cwd = Path.expand(File.cwd!())
      sub = Path.join(cwd, "safety_test_#{:erlang.unique_integer([:positive])}")
      assert Safety.allowed_root?(sub) == :ok
    end

    test "rejects paths outside temp and cwd" do
      assert {:error, err} = Safety.allowed_root?("/etc")
      assert err.message =~ "must be inside temp directory"
    end

    test "rejects / directly" do
      assert {:error, _} = Safety.allowed_root?("/")
    end
  end

  describe "valid_repo_name?/1" do
    test "accepts normal atom names" do
      assert Safety.valid_repo_name?(:foo) == :ok
      assert Safety.valid_repo_name?("bar_baz") == :ok
    end

    test "rejects empty string" do
      assert {:error, _} = Safety.valid_repo_name?("")
    end

    test "rejects names with path traversal" do
      assert {:error, _} = Safety.valid_repo_name?("../../etc")
      assert {:error, _} = Safety.valid_repo_name?("foo/../bar")
    end

    test "rejects names with slashes" do
      assert {:error, _} = Safety.valid_repo_name?("foo/bar")
      assert {:error, _} = Safety.valid_repo_name?("foo\\bar")
    end
  end

  describe "real_path/1" do
    test "resolves /tmp on macOS to private/tmp" do
      assert {:ok, resolved} = Safety.real_path("/tmp")
      assert resolved == Path.expand("/private/tmp")
    end

    test "resolves custom symlinks" do
      target = Path.join(System.tmp_dir!(), "graft_rp_target_#{:erlang.unique_integer([:positive])}")
      link = Path.join(System.tmp_dir!(), "graft_rp_link_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(target)
      :ok = :file.make_symlink(String.to_charlist(target), String.to_charlist(link))

      on_exit(fn ->
        File.rm(link)
        File.rm_rf!(target)
      end)

      assert {:ok, resolved} = Safety.real_path(link)
      assert {:ok, expected} = Safety.real_path(target)
      assert resolved == expected
    end

    test "returns expanded path for non-existent tail" do
      assert {:ok, resolved} = Safety.real_path("/nonexistent/path/12345")
      assert resolved == Path.expand("/nonexistent/path/12345")
    end

    test "detects symlink loops" do
      a = Path.join(System.tmp_dir!(), "graft_loop_a_#{:erlang.unique_integer([:positive])}")
      b = Path.join(System.tmp_dir!(), "graft_loop_b_#{:erlang.unique_integer([:positive])}")
      :ok = :file.make_symlink(String.to_charlist(b), String.to_charlist(a))
      :ok = :file.make_symlink(String.to_charlist(a), String.to_charlist(b))

      on_exit(fn ->
        File.rm(a)
        File.rm(b)
      end)

      assert {:error, :loop} = Safety.real_path(a)
    end
  end

  describe "within_root?/2" do
    test "accepts child paths" do
      assert Safety.within_root?("/tmp/foo", "/tmp") == :ok
      assert Safety.within_root?("/tmp/a/b/c", "/tmp") == :ok
    end

    test "accepts exact match" do
      assert Safety.within_root?("/tmp", "/tmp") == :ok
    end

    test "rejects escaping paths" do
      assert {:error, _} = Safety.within_root?("/tmp/../etc", "/tmp")
    end

    test "revents prefix-only match" do
      assert {:error, _} = Safety.within_root?("/tmpfoo", "/tmp")
    end

    test "accepts non-existent paths inside root" do
      root = Path.join(System.tmp_dir!(), "graft_nonexist_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(root)

      on_exit(fn ->
        File.rm_rf!(root)
      end)

      assert :ok = Safety.within_root?(Path.join(root, "new_repo"), root)
    end
  end

  describe "resolve_managed_path/2" do
    test "returns resolved path when safe" do
      assert {:ok, "/tmp/foo/bar"} = Safety.resolve_managed_path("/tmp/foo", :bar)
    end

    test "returns error for unsafe name" do
      assert {:error, _} = Safety.resolve_managed_path("/tmp/foo", "../bar")
    end

    test "returns error for escaping path" do
      assert {:error, _} = Safety.resolve_managed_path("/tmp", "/etc")
    end
  end
end
