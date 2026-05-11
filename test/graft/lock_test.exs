defmodule Graft.LockTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Lock}

  @moduletag :tmp_dir

  describe "with_lock/2" do
    test "acquires, runs, releases on success", %{tmp_dir: tmp_dir} do
      assert {:ok, :worked} =
               Lock.with_lock(tmp_dir, fn ->
                 assert File.exists?(Lock.lock_path(tmp_dir))
                 {:ok, :worked}
               end)

      refute File.exists?(Lock.lock_path(tmp_dir))
    end

    test "releases lock even if fun returns an error tuple", %{tmp_dir: tmp_dir} do
      assert {:error, :nope} = Lock.with_lock(tmp_dir, fn -> {:error, :nope} end)
      refute File.exists?(Lock.lock_path(tmp_dir))
    end

    test "releases lock even if fun raises", %{tmp_dir: tmp_dir} do
      assert_raise RuntimeError, "boom", fn ->
        Lock.with_lock(tmp_dir, fn -> raise "boom" end)
      end

      refute File.exists?(Lock.lock_path(tmp_dir))
    end

    test "second concurrent acquisition fails fast with :workspace_locked",
         %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".graft"))
      File.write!(Lock.lock_path(tmp_dir), "held by test\n")

      assert {:error, %Error{kind: :workspace_locked, details: %{phase: :acquire}}} =
               Lock.with_lock(tmp_dir, fn -> flunk("must not run") end)

      # Pre-existing held lock left intact.
      assert File.read!(Lock.lock_path(tmp_dir)) == "held by test\n"
    end
  end
end
