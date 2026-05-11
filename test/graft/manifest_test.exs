defmodule Graft.ManifestTest do
  use ExUnit.Case, async: true

  alias Graft.{Error, Manifest}
  alias Graft.Manifest.Sibling

  @moduletag :tmp_dir

  describe "load/1 — happy path" do
    test "loads a valid manifest and normalizes paths", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "req_llm"))
      File.mkdir_p!(Path.join(tmp_dir, "jido"))

      write_manifest(tmp_dir, """
      %{
        root: ".",
        siblings: [
          %{name: :req_llm, path: "req_llm"},
          %{name: :jido, path: "jido"}
        ]
      }
      """)

      assert {:ok, %Manifest{} = m} = Manifest.load(tmp_dir)

      abs_root = Path.expand(tmp_dir)
      assert m.root == abs_root
      assert m.root_declared == "."
      assert m.source_path == Path.join(tmp_dir, "graft.exs")

      assert [
               %Sibling{name: :req_llm, path: "req_llm", absolute_path: ar},
               %Sibling{name: :jido, path: "jido", absolute_path: aj}
             ] = m.siblings

      assert ar == Path.join(abs_root, "req_llm")
      assert aj == Path.join(abs_root, "jido")
    end

    test "accepts an absolute root", %{tmp_dir: tmp_dir} do
      abs_tmp = Path.expand(tmp_dir)

      write_manifest(tmp_dir, """
      %{
        root: #{inspect(abs_tmp)},
        siblings: [%{name: :a, path: "a"}]
      }
      """)

      assert {:ok, %Manifest{root: ^abs_tmp, root_declared: ^abs_tmp}} = Manifest.load(tmp_dir)
    end

    test "accepts an empty siblings list", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: []}|)
      assert {:ok, %Manifest{siblings: []}} = Manifest.load(tmp_dir)
    end
  end

  describe "load/1 — failures" do
    test "missing manifest file", %{tmp_dir: tmp_dir} do
      assert {:error, %Error{kind: :manifest_not_found}} = Manifest.load(tmp_dir)
    end

    test "manifest evaluates to a non-map", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ":ok")
      assert {:error, %Error{kind: :manifest_invalid_shape}} = Manifest.load(tmp_dir)
    end

    test "manifest fails to evaluate", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, "this is not valid elixir {{{")
      assert {:error, %Error{kind: :manifest_eval_failed}} = Manifest.load(tmp_dir)
    end

    test "missing :root", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, "%{siblings: []}")

      assert {:error, %Error{kind: :manifest_invalid_field, details: %{key: :root}}} =
               Manifest.load(tmp_dir)
    end

    test ":root is not a binary", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, "%{root: :nope, siblings: []}")
      assert {:error, %Error{kind: :manifest_invalid_field}} = Manifest.load(tmp_dir)
    end

    test "missing :siblings", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: "."}|)

      assert {:error, %Error{kind: :manifest_invalid_field, details: %{key: :siblings}}} =
               Manifest.load(tmp_dir)
    end

    test ":siblings is not a list", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: %{}}|)
      assert {:error, %Error{kind: :manifest_invalid_field}} = Manifest.load(tmp_dir)
    end

    test "sibling missing :name", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{path: "a"}]}|)

      assert {:error, %Error{kind: :manifest_invalid_field, details: %{key: :name}}} =
               Manifest.load(tmp_dir)
    end

    test "sibling :name is not an atom", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: "a", path: "a"}]}|)
      assert {:error, %Error{kind: :manifest_invalid_field}} = Manifest.load(tmp_dir)
    end

    test "sibling missing :path", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: :a}]}|)

      assert {:error, %Error{kind: :manifest_invalid_field, details: %{key: :path}}} =
               Manifest.load(tmp_dir)
    end

    test "sibling :path is not a binary", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: :a, path: :a}]}|)
      assert {:error, %Error{kind: :manifest_invalid_field}} = Manifest.load(tmp_dir)
    end

    test "sibling is not a map", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [:not_a_map]}|)
      assert {:error, %Error{kind: :manifest_invalid_field}} = Manifest.load(tmp_dir)
    end

    test "duplicate sibling name includes indices and paths", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, """
      %{
        root: ".",
        siblings: [
          %{name: :a, path: "one"},
          %{name: :a, path: "two"}
        ]
      }
      """)

      assert {:error, %Error{kind: :manifest_duplicate_sibling_name, message: msg, details: details}} =
               Manifest.load(tmp_dir)

      assert details.duplicate == :a
      assert details.count == 2
      assert details.indices == [0, 1]
      assert details.paths == ["one", "two"]
      assert msg =~ "at indices 0, 1"
    end

    test "duplicate sibling path includes indices and names", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, """
      %{
        root: ".",
        siblings: [
          %{name: :a, path: "shared"},
          %{name: :b, path: "shared"}
        ]
      }
      """)

      assert {:error, %Error{kind: :manifest_duplicate_sibling_path, message: msg, details: details}} =
               Manifest.load(tmp_dir)

      assert details.count == 2
      assert details.indices == [0, 1]
      assert details.names == [:a, :b]
      assert msg =~ "at indices 0, 1"
    end

    test "sibling path escapes the workspace root", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, """
      %{
        root: ".",
        siblings: [%{name: :evil, path: "../outside"}]
      }
      """)

      assert {:error, %Error{kind: :manifest_sibling_outside_root, details: details}} =
               Manifest.load(tmp_dir)

      assert details.name == :evil
      assert details.index == 0
      assert details.resolved =~ "outside"
    end

    test "sibling path equal to workspace root is rejected (must be strictly inside)",
         %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: :self, path: "."}]}|)

      assert {:error, %Error{kind: :manifest_sibling_outside_root, details: details}} =
               Manifest.load(tmp_dir)

      assert details.name == :self
      assert details.index == 0
    end

    test "sibling missing :path includes name in error", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: :a}]}|)

      assert {:error, %Error{kind: :manifest_invalid_field, message: msg, details: details}} =
               Manifest.load(tmp_dir)

      assert details.key == :path
      assert details.name == :a
      assert msg =~ "Sibling :a at index 0"
    end

    test "sibling :path is not a binary includes name in error", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, ~s|%{root: ".", siblings: [%{name: :a, path: :a}]}|)

      assert {:error, %Error{kind: :manifest_invalid_field, message: msg, details: details}} =
               Manifest.load(tmp_dir)

      assert details.key == :path
      assert details.name == :a
      assert msg =~ "Sibling :a at index 0"
    end
  end

  describe "filename/0" do
    test "returns the canonical filename" do
      assert Manifest.filename() == "graft.exs"
    end
  end

  defp write_manifest(dir, contents) do
    File.write!(Path.join(dir, "graft.exs"), contents)
  end
end
