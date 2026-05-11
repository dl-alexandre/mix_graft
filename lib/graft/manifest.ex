defmodule Graft.Manifest do
  @moduledoc """
  Loads and validates `graft.exs` — the workspace manifest.

  Format (eval'd as Elixir):

      %{
        root: ".",
        siblings: [
          %{name: :req_llm, path: "req_llm"},
          %{name: :jido,    path: "jido"}
        ]
      }

  ## Validation

  * file must exist at `<dir>/graft.exs`
  * the file must evaluate to a map
  * `:root` must be a binary path (relative or absolute)
  * `:siblings` must be a list
  * every sibling must declare an atom `:name` and a binary `:path`
  * sibling names must be unique
  * sibling paths must be unique
  * every resolved sibling path must remain strictly inside the
    workspace root (no `..` escape)

  ## Normalization

  The returned struct exposes both absolute (`root`, `Sibling.absolute_path`)
  and original (`root_declared`, `Sibling.path`) forms — the absolute forms
  for actual filesystem work, the originals for display and state-file
  recording.
  """

  alias Graft.Error

  defmodule Sibling do
    @moduledoc "A sibling repo declared in `graft.exs`."

    @type t :: %__MODULE__{
            name: atom(),
            path: Path.t(),
            absolute_path: Path.t()
          }

    defstruct [:name, :path, :absolute_path]
  end

  @type t :: %__MODULE__{
          root: Path.t(),
          root_declared: Path.t(),
          siblings: [Sibling.t()],
          source_path: Path.t()
        }

  defstruct [:root, :root_declared, :siblings, :source_path]

  @manifest_filename "graft.exs"

  @doc "The conventional manifest filename."
  @spec filename() :: String.t()
  def filename, do: @manifest_filename

  @doc """
  Load and validate the manifest from `dir` (defaults to `File.cwd!/0`).

  Side-effect free: reads the manifest file and resolves paths via
  `Path.expand/2` only. No filesystem mutations, no shell-outs.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(dir \\ File.cwd!()) when is_binary(dir) do
    path = Path.join(dir, @manifest_filename)

    with {:ok, raw} <- read_and_eval(path),
         {:ok, root_declared, siblings_raw} <- validate_top_level(raw),
         abs_root = Path.expand(root_declared, dir),
         {:ok, siblings} <- validate_siblings(siblings_raw, abs_root) do
      {:ok,
       %__MODULE__{
         root: abs_root,
         root_declared: root_declared,
         siblings: siblings,
         source_path: path
       }}
    end
  end

  ## ─── Read / parse ─────────────────────────────────────────────────────

  # Parses graft.exs via Code.string_to_quoted/1 instead of
  # Code.eval_file/2 for safety: the manifest is data, not code.
  # Only literal maps, lists, atoms, and strings are permitted.
  defp read_and_eval(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, source} ->
          case Code.string_to_quoted(source) do
            {:ok, ast} ->
              try do
                parse_manifest_ast(ast)
              catch
                {:error, %Error{} = err} ->
                  {:error, %{err | details: Map.put(err.details || %{}, :path, path)}}
              end

            {:error, {_meta, message, _token}} ->
              {:error,
               Error.new(
                 :manifest_eval_failed,
                 "Failed to parse #{path}: #{message}",
                 %{path: path}
               )}
          end

        {:error, reason} ->
          {:error,
           Error.new(
             :manifest_not_found,
             "Could not read #{path}: #{inspect(reason)}",
             %{path: path}
           )}
      end
    else
      {:error,
       Error.new(
         :manifest_not_found,
         "No #{@manifest_filename} found at #{path}",
         %{path: path}
       )}
    end
  end

  # Accept: %{root: "...", siblings: [...]}
  defp parse_manifest_ast({:%{}, _meta, fields}) do
    {:ok, Map.new(parse_map_fields(fields))}
  end

  defp parse_manifest_ast(other) do
    {:error,
     Error.new(
       :manifest_invalid_shape,
       "Manifest must be a literal map, got: #{Macro.to_string(other)}",
       %{ast: other}
     )}
  end

  defp parse_map_fields(fields) when is_list(fields) do
    Enum.map(fields, fn
      {key, value} when is_atom(key) ->
        {key, parse_literal(value)}

      other ->
        throw({:error, Error.new(:manifest_invalid_field, "Map keys must be atoms, got: #{inspect(other)}")})
    end)
  end

  # Literal value parser — only data, no function calls, no variables
  defp parse_literal({:%{}, _meta, fields}), do: Map.new(parse_map_fields(fields))
  defp parse_literal({_, _meta, list}) when is_list(list), do: Enum.map(list, &parse_literal/1)
  defp parse_literal(list) when is_list(list), do: Enum.map(list, &parse_literal/1)
  defp parse_literal(atom) when is_atom(atom), do: atom
  defp parse_literal(string) when is_binary(string), do: string
  defp parse_literal(integer) when is_integer(integer), do: integer
  defp parse_literal(boolean) when is_boolean(boolean), do: boolean
  defp parse_literal(nil), do: nil

  defp parse_literal(other) do
    throw({:error, Error.new(:manifest_invalid_field, "Only literal values permitted in manifest, got: #{Macro.to_string(other)}")})
  end

  ## ─── Top-level shape ────────────────────────────────────────────────

  defp validate_top_level(raw) when is_map(raw) do
    with {:ok, root} <- fetch_field(raw, :root, &is_binary/1, "binary path"),
         {:ok, siblings} <- fetch_field(raw, :siblings, &is_list/1, "list") do
      {:ok, root, siblings}
    end
  end

  defp validate_top_level(other) do
    {:error,
     Error.new(
       :manifest_invalid_shape,
       "graft.exs must evaluate to a map, got #{inspect(other)}",
       %{value: other}
     )}
  end

  defp fetch_field(map, key, predicate, expected) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if predicate.(value) do
          {:ok, value}
        else
          {:error,
           Error.new(
             :manifest_invalid_field,
             "Manifest field #{inspect(key)} must be a #{expected}, got #{inspect(value)}",
             %{key: key, value: value}
           )}
        end

      :error ->
        {:error,
         Error.new(
           :manifest_invalid_field,
           "Manifest is missing required field #{inspect(key)}",
           %{key: key}
         )}
    end
  end

  ## ─── Sibling validation ─────────────────────────────────────────────

  defp validate_siblings(raw_siblings, abs_root) do
    raw_siblings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case build_sibling(raw, idx, abs_root) do
        {:ok, sibling} -> {:cont, {:ok, [sibling | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} ->
        siblings = Enum.reverse(reversed)

        with :ok <- check_unique(siblings, & &1.name, :manifest_duplicate_sibling_name, "name"),
             :ok <-
               check_unique(
                 siblings,
                 & &1.absolute_path,
                 :manifest_duplicate_sibling_path,
                 "path"
               ) do
          {:ok, siblings}
        end

      err ->
        err
    end
  end

  defp build_sibling(raw, idx, abs_root) when is_map(raw) do
    with {:ok, name} <- fetch_sibling_field(raw, :name, &is_atom/1, "atom", idx),
         {:ok, path} <- fetch_sibling_field(raw, :path, &is_binary/1, "binary", idx, %{name: name}),
         abs = Path.expand(path, abs_root),
         :ok <- check_inside_root(abs, abs_root, name, path, idx) do
      {:ok, %Sibling{name: name, path: path, absolute_path: abs}}
    end
  end

  defp build_sibling(other, idx, _abs_root) do
    {:error,
     Error.new(
       :manifest_invalid_field,
       "Sibling at index #{idx} must be a map, got #{inspect(other)}",
       %{index: idx, value: other}
     )}
  end

  defp fetch_sibling_field(map, key, predicate, expected, idx, context \\ %{}) do
    case Map.fetch(map, key) do
      {:ok, v} ->
        if predicate.(v) do
          {:ok, v}
        else
          context_msg = if name = context[:name], do: " #{inspect(name)}", else: ""

          {:error,
           Error.new(
             :manifest_invalid_field,
             "Sibling#{context_msg} at index #{idx}: #{inspect(key)} must be #{expected}, got #{inspect(v)}",
             %{index: idx, key: key, value: v, name: context[:name]}
           )}
        end

      :error ->
        context_msg = if name = context[:name], do: " #{inspect(name)}", else: ""

        {:error,
         Error.new(
           :manifest_invalid_field,
           "Sibling#{context_msg} at index #{idx} is missing required field #{inspect(key)}",
           %{index: idx, key: key, name: context[:name]}
         )}
    end
  end

  defp check_inside_root(abs_sibling, abs_root, name, original_path, idx) do
    if inside?(abs_sibling, abs_root) do
      :ok
    else
      {:error,
       Error.new(
         :manifest_sibling_outside_root,
         "Sibling #{inspect(name)} at index #{idx} resolves to #{abs_sibling}, which is outside the workspace root #{abs_root}",
         %{index: idx, name: name, path: original_path, resolved: abs_sibling, root: abs_root}
       )}
    end
  end

  # The sibling must live strictly inside the root (not equal to it, not above it).
  defp inside?(abs_sibling, abs_root) do
    String.starts_with?(abs_sibling, abs_root <> "/")
  end

  defp check_unique(siblings, key_fun, kind, label) do
    siblings
    |> Enum.with_index()
    |> Enum.group_by(fn {sib, _idx} -> key_fun.(sib) end)
    |> Enum.find(fn {_k, pairs} -> length(pairs) > 1 end)
    |> case do
      nil ->
        :ok

      {dup, pairs} ->
        indices = Enum.map(pairs, fn {_sib, idx} -> idx end)

        details = %{
          duplicate: dup,
          count: length(pairs),
          indices: indices
        }

        # Include names/paths in the details for richer diagnostics
        details =
          if label == "name" do
            paths = Enum.map(pairs, fn {sib, _idx} -> sib.path end)
            Map.put(details, :paths, paths)
          else
            names = Enum.map(pairs, fn {sib, _idx} -> sib.name end)
            Map.put(details, :names, names)
          end

        {:error,
         Error.new(
           kind,
           "Duplicate sibling #{label}: #{inspect(dup)} appears #{length(pairs)} times " <>
             "at indices #{Enum.join(indices, ", ")}",
           details
         )}
    end
  end
end
