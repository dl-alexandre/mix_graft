defmodule Graft.Link.RewriterTest do
  use ExUnit.Case, async: true

  alias Graft.Error
  alias Graft.Link.{Rewriter, RewriteResult}

  describe "rewrite/3 — simple version → path" do
    test "rewrites {:foo, version} to {:foo, path: ...}" do
      source = wrap_deps([~s|{:foo, "~> 1.0"}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert %RewriteResult{matched_dep?: true, changed?: true} = result
      assert result.rewritten_contents =~ ~s|{:foo, path: "../foo"}|
      refute result.rewritten_contents =~ ~s|"~> 1.0"|
    end

    test "preserves all surrounding code" do
      source = """
      defmodule Sib.MixProject do
        use Mix.Project

        @version "0.1.0"

        def project, do: [app: :sib, version: @version, deps: deps()]

        defp deps do
          [
            {:foo, "~> 1.0"},
            {:bar, "~> 2.0"}
          ]
        end

        defp aliases, do: ["hello world"]
      end
      """

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ ~s|@version "0.1.0"|
      assert result.rewritten_contents =~ ~s|defp aliases|
      assert result.rewritten_contents =~ ~s|{:bar, "~> 2.0"}|
      assert result.rewritten_contents =~ ~s|{:foo, path: "../foo"}|
    end
  end

  describe "rewrite/3 — preserve `only:` and other non-source opts" do
    test "drops version, keeps only: opt" do
      source = wrap_deps([~s|{:foo, "~> 1.0", only: :dev}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.matched_dep?
      assert result.changed?
      assert result.rewritten_contents =~ ~s|path: "../foo"|
      assert result.rewritten_contents =~ ~s|only: :dev|
      refute result.rewritten_contents =~ ~s|"~> 1.0"|
    end

    test "preserves multiple non-source opts" do
      source = wrap_deps([~s|{:foo, "~> 1.0", only: [:dev, :test], runtime: false}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ ~s|path: "../foo"|
      assert result.rewritten_contents =~ ~s|only:|
      assert result.rewritten_contents =~ ~s|runtime: false|
    end

    test "preserves non-source opts when original was a kw-list 2-tuple" do
      source = wrap_deps([~s|{:foo, git: "https://x/y.git", branch: "main", only: :test}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ ~s|path: "../foo"|
      assert result.rewritten_contents =~ ~s|only: :test|
      refute result.rewritten_contents =~ "git:"
      refute result.rewritten_contents =~ "branch:"
    end
  end

  describe "rewrite/3 — source swaps" do
    test "git → path" do
      source = wrap_deps([~s|{:foo, git: "https://x/y.git", branch: "main"}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ ~s|path: "../foo"|
      refute result.rewritten_contents =~ "git:"
      refute result.rewritten_contents =~ "branch:"
    end

    test "path → git (multi-key replacement)" do
      source = wrap_deps([~s|{:foo, path: "../foo"}|])

      {:ok, result} =
        Rewriter.rewrite(source, :foo, git: "https://x/y.git", branch: "main")

      assert result.rewritten_contents =~ ~s|git: "https://x/y.git"|
      assert result.rewritten_contents =~ ~s|branch: "main"|
      refute result.rewritten_contents =~ ~s|path:|
    end
  end

  describe "rewrite/3 — comments and formatting" do
    test "preserves comments adjacent to the rewritten dep" do
      source = """
      defmodule Sib.MixProject do
        use Mix.Project
        def project, do: [app: :sib, version: "0.1.0", deps: deps()]

        defp deps do
          [
            # the LLM client
            {:foo, "~> 1.0"},
            # other deps
            {:bar, "~> 2.0"}
          ]
        end
      end
      """

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ "# the LLM client"
      assert result.rewritten_contents =~ "# other deps"
      assert result.rewritten_contents =~ ~s|{:foo, path: "../foo"}|
    end

    test "preserves the trailing newline state of the original" do
      with_nl = wrap_deps([~s|{:foo, "~> 1.0"}|])
      assert String.ends_with?(with_nl, "\n")

      {:ok, result_with} = Rewriter.rewrite(with_nl, :foo, path: "../foo")
      assert String.ends_with?(result_with.rewritten_contents, "\n")

      without_nl = String.trim_trailing(with_nl, "\n")
      refute String.ends_with?(without_nl, "\n")

      {:ok, result_without} = Rewriter.rewrite(without_nl, :foo, path: "../foo")
      refute String.ends_with?(result_without.rewritten_contents, "\n")
    end
  end

  describe "rewrite/3 — dep absent" do
    test "returns matched_dep?: false, changed?: false when dep is missing" do
      source = wrap_deps([~s|{:bar, "~> 2.0"}|])

      assert {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")
      assert result.matched_dep? == false
      assert result.changed? == false
      assert result.rewritten_contents == source
      assert is_nil(result.original_dep_ast)
      assert is_nil(result.rewritten_dep_ast)
    end

    test "returns no-op when there is no deps function at all" do
      source = """
      defmodule Sib.MixProject do
        use Mix.Project
        def project, do: [app: :sib, version: "0.1.0"]
      end
      """

      assert {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")
      assert result.matched_dep? == false
      assert result.rewritten_contents == source
    end
  end

  describe "rewrite/3 — only the matching dep changes" do
    test "unrelated deps are byte-identical in the rewritten output" do
      source =
        wrap_deps([
          ~s|{:bar, "~> 2.0"}|,
          ~s|{:foo, "~> 1.0"}|,
          ~s|{:baz, "~> 3.0", only: :test}|
        ])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.rewritten_contents =~ ~s|{:bar, "~> 2.0"}|
      assert result.rewritten_contents =~ ~s|{:baz, "~> 3.0", only: :test}|
      assert result.rewritten_contents =~ ~s|{:foo, path: "../foo"}|
    end
  end

  describe "rewrite/3 — errors" do
    test "malformed source returns rewriter_malformed_source" do
      assert {:error, %Error{kind: :rewriter_malformed_source}} =
               Rewriter.rewrite("this is not (((( elixir", :foo, path: "../foo")
    end

    test "empty replacement opts returns rewriter_invalid_replacement" do
      source = wrap_deps([~s|{:foo, "~> 1.0"}|])

      assert {:error, %Error{kind: :rewriter_invalid_replacement}} =
               Rewriter.rewrite(source, :foo, [])
    end

    test "replacement without a source identifier key is rejected" do
      source = wrap_deps([~s|{:foo, "~> 1.0"}|])

      assert {:error, %Error{kind: :rewriter_invalid_replacement, details: %{got: got}}} =
               Rewriter.rewrite(source, :foo, only: :test)

      assert :only in got
    end
  end

  describe "rewrite/3 — determinism" do
    test "rewriting the same input twice yields byte-identical output" do
      source = wrap_deps([~s|{:foo, "~> 1.0", only: :dev}|])

      {:ok, r1} = Rewriter.rewrite(source, :foo, path: "../foo")
      {:ok, r2} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert r1.rewritten_contents == r2.rewritten_contents
    end

    test "no-op rewrite is also stable" do
      source = wrap_deps([~s|{:bar, "~> 2.0"}|])
      {:ok, r1} = Rewriter.rewrite(source, :foo, path: "../foo")
      {:ok, r2} = Rewriter.rewrite(source, :foo, path: "../foo")
      assert r1 == r2
    end
  end

  describe "rewrite/3 — RewriteResult contents" do
    test "exposes both original and rewritten dep ASTs" do
      source = wrap_deps([~s|{:foo, "~> 1.0"}|])

      {:ok, result} = Rewriter.rewrite(source, :foo, path: "../foo")

      assert result.original_dep_ast != nil
      assert result.rewritten_dep_ast != nil
      assert result.original_dep_ast != result.rewritten_dep_ast

      assert Sourceror.to_string(result.original_dep_ast) =~ ~s|{:foo, "~> 1.0"}|
      assert Sourceror.to_string(result.rewritten_dep_ast) =~ ~s|path: "../foo"|
    end
  end

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp wrap_deps(dep_lines) do
    inner = Enum.map_join(dep_lines, ",\n      ", & &1)

    """
    defmodule Sib.MixProject do
      use Mix.Project

      def project, do: [app: :sib, version: "0.1.0", deps: deps()]

      defp deps do
        [
          #{inner}
        ]
      end
    end
    """
  end
end
