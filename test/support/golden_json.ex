defmodule Graft.GoldenJSON do
  @moduledoc false

  # Golden-file harness for Graft's machine-readable JSON contracts.
  #
  # `assert_match/3` decodes the actual JSON, scrubs volatile fields
  # (paths under the workspace root, `generated_at`, `duration_ms`), and
  # compares against the file at `test/golden/<name>.json`. The scrubbed
  # form is the *frozen contract* — adding or renaming a field requires
  # consciously regenerating the golden via:
  #
  #     GRAFT_UPDATE_GOLDEN=1 mix test test/contrib/golden_test.exs

  import ExUnit.Assertions

  @golden_dir Path.expand("../golden", __DIR__)

  @doc "Path to the golden file directory."
  def golden_dir, do: @golden_dir

  @doc """
  Compare `actual_json` (a JSON string) against the golden named `name`.
  Required option:

    * `:root` — workspace root path; any string starting with it is
      rewritten to `<ROOT>/...` so the golden survives across tmp dirs.
  """
  def assert_match(actual_json, name, opts) when is_binary(actual_json) and is_list(opts) do
    root = Keyword.fetch!(opts, :root)
    normalized = normalize(actual_json, root)
    path = Path.join(@golden_dir, "#{name}.json")

    if System.get_env("GRAFT_UPDATE_GOLDEN") == "1" do
      File.mkdir_p!(@golden_dir)
      File.write!(path, normalized <> "\n")
      :ok
    else
      expected =
        case File.read(path) do
          {:ok, contents} ->
            String.trim_trailing(contents, "\n")

          {:error, _} ->
            flunk("""
            Missing golden file: #{path}
            Re-run with GRAFT_UPDATE_GOLDEN=1 to generate.
            """)
        end

      assert normalized == expected, """
      Golden mismatch for #{name}.

      --- expected
      #{expected}

      --- actual
      #{normalized}

      If this change is intentional, re-run with GRAFT_UPDATE_GOLDEN=1.
      """
    end
  end

  @doc false
  def normalize(json, root) do
    json
    |> Jason.decode!()
    |> scrub(root)
    |> Jason.encode!(pretty: true)
  end

  @doc """
  JSONL-aware variant. `actual_jsonl` is newline-delimited JSON; the
  golden file is rendered as a JSON array of normalized events for
  human-readable diffing.
  """
  def assert_match_jsonl(actual_jsonl, name, opts)
      when is_binary(actual_jsonl) and is_list(opts) do
    root = Keyword.fetch!(opts, :root)

    events =
      actual_jsonl
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&scrub(&1, root))

    normalized = Jason.encode!(events, pretty: true)
    path = Path.join(@golden_dir, "#{name}.json")

    if System.get_env("GRAFT_UPDATE_GOLDEN") == "1" do
      File.mkdir_p!(@golden_dir)
      File.write!(path, normalized <> "\n")
      :ok
    else
      expected =
        case File.read(path) do
          {:ok, contents} ->
            String.trim_trailing(contents, "\n")

          {:error, _} ->
            flunk("""
            Missing golden file: #{path}
            Re-run with GRAFT_UPDATE_GOLDEN=1 to generate.
            """)
        end

      assert normalized == expected, """
      Golden JSONL mismatch for #{name}.

      --- expected
      #{expected}

      --- actual
      #{normalized}

      If this change is intentional, re-run with GRAFT_UPDATE_GOLDEN=1.
      """
    end
  end

  defp scrub(value, root) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, scrub_value(k, v, root)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp scrub(value, root) when is_list(value) do
    Enum.map(value, &scrub(&1, root))
  end

  defp scrub(value, _root), do: value

  defp scrub_value("generated_at", _v, _root), do: "<GENERATED_AT>"
  defp scrub_value("duration_ms", _v, _root), do: 0

  defp scrub_value(_k, v, root) when is_binary(v) do
    cond do
      root && v == root ->
        "<ROOT>"

      root && String.starts_with?(v, root <> "/") ->
        "<ROOT>" <> String.replace_prefix(v, root, "")

      true ->
        v
    end
  end

  defp scrub_value(_k, v, root), do: scrub(v, root)
end
