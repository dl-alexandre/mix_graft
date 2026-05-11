defmodule Graft.ListTest do
  use ExUnit.Case, async: true

  alias Graft.List

  describe "render/2 — text" do
    test "empty manifest shows zero siblings" do
      dir = tmp_dir()
      write_manifest(dir, ~s|%{root: ".", siblings: []}|)

      assert {:ok, output} = List.render(dir, :text)
      assert output =~ "Siblings (0):"
    end

    test "lists siblings with existence markers" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "req_llm"))
      # jido is NOT created — should show [missing]

      write_manifest(dir, """
      %{
        root: ".",
        siblings: [
          %{name: :req_llm, path: "req_llm"},
          %{name: :jido, path: "jido"}
        ]
      }
      """)

      assert {:ok, output} = List.render(dir, :text)
      assert output =~ "Siblings (2):"
      assert output =~ "req_llm"
      assert output =~ "[exists]"
      assert output =~ "jido"
      assert output =~ "[missing]"
    end

    test "returns error for missing manifest" do
      dir = tmp_dir()
      assert {:error, %{kind: :manifest_not_found}} = List.render(dir, :text)
    end
  end

  describe "render/2 — json" do
    test "renders structured data" do
      dir = tmp_dir()
      File.mkdir_p!(Path.join(dir, "a"))

      write_manifest(dir, ~s|%{root: ".", siblings: [%{name: :a, path: "a"}]}|)

      assert {:ok, json} = List.render(dir, :json)
      decoded = Jason.decode!(json)
      assert decoded["sibling_count"] == 1
      assert [sib] = decoded["siblings"]
      assert sib["name"] == "a"
      assert sib["path"] == "a"
      assert sib["exists"] == true
      assert sib["absolute_path"] == Path.join(dir, "a")
    end

    test "marks missing siblings" do
      dir = tmp_dir()

      write_manifest(dir, ~s|%{root: ".", siblings: [%{name: :ghost, path: "ghost"}]}|)

      assert {:ok, json} = List.render(dir, :json)
      decoded = Jason.decode!(json)
      assert [sib] = decoded["siblings"]
      assert sib["exists"] == false
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp tmp_dir do
    rand = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    dir = Path.join(System.tmp_dir!(), "graft_list_test_#{rand}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest(dir, contents) do
    File.write!(Path.join(dir, "graft.exs"), contents <> "\n")
  end
end
