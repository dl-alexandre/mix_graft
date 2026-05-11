defmodule Graft.State do
  @moduledoc """
  Read, write, and validate `.graft/state.json` — the local link-state
  record that backs `link.off` revert.

  The file is gitignored and per-developer; it is not shared config. Each
  entry records the exact pre/post hashes flanking a Graft rewrite plus
  the dep-tuple text before and after, so revert is a literal restore
  (never an inverse AST rewrite).

  ## Invariants

    * Saving only writes `.graft/state.json` (and creates `.graft/`
      if needed). No other files are touched.
    * Loading is side-effect free.
    * Atom values cross the JSON boundary as strings; on load they are
      resolved with `String.to_existing_atom/1` so untrusted input
      cannot inflate the atom table.
    * Validation is strict: missing or wrongly typed fields produce a
      structured `Graft.Error{}`, not a partial struct.
  """

  alias Graft.{Error, Link.Plan}
  alias Graft.State.Entry

  @schema_version 1
  @state_dir ".graft"
  @state_file "state.json"

  @type t :: %__MODULE__{
          version: pos_integer(),
          workspace_root: Path.t(),
          generated_at: String.t(),
          entries: [Entry.t()]
        }

  defstruct [:version, :workspace_root, :generated_at, entries: []]

  @doc "The conventional path for the state file under `root`."
  @spec state_path(Path.t()) :: Path.t()
  def state_path(root), do: Path.join([root, @state_dir, @state_file])

  @doc "Current schema version Graft writes."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Migrate a loaded state to the current schema version.

  Today this is the identity transformation for v1. The dispatch point
  exists so a future v2 schema can land without churning call sites.

    * `%State{version: 1}` → `{:ok, state}` (identity)
    * `%State{version: v}` for integer `v` ≠ 1 → `:state_unsupported_version`
    * Anything else (nil/non-integer version, non-State input) →
      `:state_invalid_field`
  """
  @spec migrate(t()) :: {:ok, t()} | {:error, Error.t()}
  def migrate(%__MODULE__{version: 1} = state), do: {:ok, state}

  def migrate(%__MODULE__{version: v}) when is_integer(v) do
    {:error,
     Error.new(
       :state_unsupported_version,
       "Unsupported state schema version #{inspect(v)} (expected #{@schema_version})",
       %{got: v, expected: @schema_version}
     )}
  end

  def migrate(%__MODULE__{version: v}) do
    {:error,
     Error.new(
       :state_invalid_field,
       "State has malformed or missing 'version' field: #{inspect(v)}",
       %{key: "version", value: v}
     )}
  end

  def migrate(other) do
    {:error,
     Error.new(
       :state_invalid_field,
       "migrate/1 expected a %Graft.State{}, got: #{inspect(other)}",
       %{value: other}
     )}
  end

  @doc """
  Like `load/1` but treats a missing state file as an empty state. Other
  load failures (parse error, schema mismatch, unknown atom) still
  surface as a structured error.
  """
  @spec load_or_empty(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load_or_empty(root) when is_binary(root) do
    case load(root) do
      {:ok, state} ->
        {:ok, state}

      {:error, %Error{kind: :state_io_error, details: %{reason: :enoent}}} ->
        {:ok,
         %__MODULE__{
           version: @schema_version,
           workspace_root: root,
           generated_at: DateTime.to_iso8601(DateTime.utc_now()),
           entries: []
         }}

      {:error, %Error{}} = err ->
        err
    end
  end

  @doc """
  Merge a fresh `Plan`-derived state into an existing state. Entries
  with matching `{repo, target_app}` are replaced; unrelated existing
  entries are preserved. Output entries are sorted by
  `(repo, target_app)` for deterministic serialization.
  """
  @spec merge_with_plan(t(), Plan.t()) :: t()
  def merge_with_plan(%__MODULE__{} = existing, %Plan{} = plan) do
    incoming = from_plan(plan)
    keys_to_replace = MapSet.new(incoming.entries, &entry_key/1)

    preserved = Enum.reject(existing.entries, &MapSet.member?(keys_to_replace, entry_key(&1)))

    merged_entries =
      (preserved ++ incoming.entries)
      |> Enum.sort_by(&{Atom.to_string(&1.repo), Atom.to_string(&1.target_app)})

    %__MODULE__{
      version: @schema_version,
      workspace_root: plan.workspace_root,
      generated_at: incoming.generated_at,
      entries: merged_entries
    }
  end

  defp entry_key(%Entry{repo: repo, target_app: target_app}), do: {repo, target_app}

  ## ─── Hashing ────────────────────────────────────────────────────────

  @doc """
  Lowercase hex SHA-256 of `contents`.
  """
  @spec hash_contents(binary()) :: String.t()
  def hash_contents(contents) when is_binary(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end

  ## ─── Build from a plan ──────────────────────────────────────────────

  @doc """
  Project a `Graft.Link.Plan` into a `State` ready for serialization.
  Only changes that the runner will actually write contribute entries —
  no-op changes (`changed?: false`) are skipped because they need no
  revert record.
  """
  @spec from_plan(Plan.t()) :: t()
  def from_plan(%Plan{} = plan) do
    entries =
      plan.changes
      |> Enum.filter(& &1.changed?)
      |> Enum.map(&change_to_entry(&1, plan.operation))

    %__MODULE__{
      version: @schema_version,
      workspace_root: plan.workspace_root,
      generated_at: DateTime.to_iso8601(plan.generated_at),
      entries: entries
    }
  end

  defp change_to_entry(change, operation) do
    %Entry{
      repo: change.repo,
      repo_path: change.repo_path,
      target_app: change.target_app,
      mix_exs_path: Path.join(change.repo_path, "mix.exs"),
      mix_exs_before_hash: change.mix_exs_before_hash,
      mix_exs_after_hash: change.proposed_mix_exs_after_hash,
      preimage: change.dependency_source_before,
      replacement: change.dependency_source_after,
      operation: operation
    }
  end

  ## ─── Save ───────────────────────────────────────────────────────────

  @doc """
  Persist `state` as pretty JSON at `root/.graft/state.json`. The
  parent directory is created if missing. Returns `:ok` or a structured
  error.
  """
  @spec save(Path.t(), t()) :: :ok | {:error, Error.t()}
  def save(root, %__MODULE__{} = state) when is_binary(root) do
    path = state_path(root)
    json = encode(state)

    with :ok <- ensure_dir(Path.dirname(path)),
         :ok <- write_file(path, json) do
      :ok
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :state_io_error,
           "Failed to create #{dir}: #{:file.format_error(reason)}",
           %{path: dir, reason: reason}
         )}
    end
  end

  defp write_file(path, contents) do
    case File.write(path, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :state_io_error,
           "Failed to write #{path}: #{:file.format_error(reason)}",
           %{path: path, reason: reason}
         )}
    end
  end

  ## ─── Load ───────────────────────────────────────────────────────────

  @doc """
  Read and validate `root/.graft/state.json`. Side-effect free.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load(root) when is_binary(root) do
    path = state_path(root)

    with {:ok, raw} <- read_file(path),
         {:ok, decoded} <- decode_json(raw, path),
         {:ok, state} <- validate(decoded) do
      {:ok, state}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Error.new(
           :state_io_error,
           "Failed to read #{path}: #{:file.format_error(reason)}",
           %{path: path, reason: reason}
         )}
    end
  end

  defp decode_json(raw, path) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = e} ->
        {:error,
         Error.new(
           :state_invalid_json,
           "Failed to parse #{path}: #{Exception.message(e)}",
           %{path: path}
         )}
    end
  end

  ## ─── Validation ─────────────────────────────────────────────────────

  defp validate(decoded) when is_map(decoded) do
    with {:ok, version} <- fetch_int(decoded, "version"),
         :ok <- check_version(version),
         {:ok, root} <- fetch_string(decoded, "workspace_root"),
         {:ok, generated_at} <- fetch_string(decoded, "generated_at"),
         {:ok, raw_entries} <- fetch_list(decoded, "entries"),
         {:ok, entries} <- validate_entries(raw_entries) do
      {:ok,
       %__MODULE__{
         version: version,
         workspace_root: root,
         generated_at: generated_at,
         entries: entries
       }}
    end
  end

  defp validate(other) do
    {:error,
     Error.new(
       :state_invalid_shape,
       "state.json must decode to a JSON object, got: #{inspect(other)}"
     )}
  end

  defp check_version(@schema_version), do: :ok

  defp check_version(other) do
    {:error,
     Error.new(
       :state_unsupported_version,
       "Unsupported state schema version #{inspect(other)} (expected #{@schema_version})",
       %{got: other, expected: @schema_version}
     )}
  end

  defp validate_entries(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, idx}, {:ok, acc} ->
      case validate_entry(raw, idx) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp validate_entry(raw, idx) when is_map(raw) do
    with {:ok, repo} <- fetch_atom(raw, "repo", idx),
         {:ok, repo_path} <- fetch_string(raw, "repo_path", idx),
         {:ok, target_app} <- fetch_atom(raw, "target_app", idx),
         {:ok, mix_exs_path} <- fetch_string(raw, "mix_exs_path", idx),
         {:ok, before_hash} <- fetch_string(raw, "mix_exs_before_hash", idx),
         {:ok, after_hash} <- fetch_string(raw, "mix_exs_after_hash", idx),
         {:ok, preimage} <- fetch_string(raw, "preimage", idx),
         {:ok, replacement} <- fetch_string(raw, "replacement", idx),
         {:ok, operation} <- fetch_atom(raw, "operation", idx),
         :ok <- check_operation(operation, idx) do
      {:ok,
       %Entry{
         repo: repo,
         repo_path: repo_path,
         target_app: target_app,
         mix_exs_path: mix_exs_path,
         mix_exs_before_hash: before_hash,
         mix_exs_after_hash: after_hash,
         preimage: preimage,
         replacement: replacement,
         operation: operation
       }}
    end
  end

  defp validate_entry(other, idx) do
    {:error,
     Error.new(
       :state_invalid_field,
       "Entry at index #{idx} must be an object, got: #{inspect(other)}",
       %{index: idx, value: other}
     )}
  end

  defp check_operation(:link_on, _idx), do: :ok

  defp check_operation(other, idx) do
    {:error,
     Error.new(
       :state_invalid_field,
       "Entry at index #{idx} has unsupported operation #{inspect(other)}",
       %{index: idx, key: "operation", value: other}
     )}
  end

  defp fetch_int(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_integer(v) ->
        {:ok, v}

      {:ok, v} ->
        {:error,
         Error.new(
           :state_invalid_field,
           "Field #{inspect(key)} must be an integer, got: #{inspect(v)}",
           %{key: key, value: v}
         )}

      :error ->
        missing(key)
    end
  end

  defp fetch_string(map, key, idx \\ nil) do
    case Map.fetch(map, key) do
      {:ok, v} when is_binary(v) ->
        {:ok, v}

      {:ok, v} ->
        {:error,
         Error.new(
           :state_invalid_field,
           "Field #{inspect(key)} must be a string, got: #{inspect(v)}",
           context(key, idx, %{value: v})
         )}

      :error ->
        missing(key, idx)
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_list(v) ->
        {:ok, v}

      {:ok, v} ->
        {:error,
         Error.new(
           :state_invalid_field,
           "Field #{inspect(key)} must be a list, got: #{inspect(v)}",
           %{key: key, value: v}
         )}

      :error ->
        missing(key)
    end
  end

  # Resolve a string field to an atom *only* if the atom already exists
  # — guards against atom-table inflation from untrusted state files.
  defp fetch_atom(map, key, idx) do
    with {:ok, s} <- fetch_string(map, key, idx) do
      try do
        {:ok, String.to_existing_atom(s)}
      rescue
        ArgumentError ->
          {:error,
           Error.new(
             :state_unknown_atom,
             "Field #{inspect(key)} references unknown atom #{inspect(s)} — load the workspace before loading state",
             context(key, idx, %{value: s})
           )}
      end
    end
  end

  defp missing(key, idx \\ nil) do
    {:error,
     Error.new(
       :state_invalid_field,
       "Missing required field #{inspect(key)}",
       context(key, idx)
     )}
  end

  defp context(key, idx, extra \\ %{})
  defp context(key, nil, extra), do: Map.merge(%{key: key}, extra)
  defp context(key, idx, extra), do: Map.merge(%{key: key, index: idx}, extra)

  ## ─── Encoding ───────────────────────────────────────────────────────

  defp encode(%__MODULE__{} = state) do
    %{
      "version" => state.version,
      "workspace_root" => state.workspace_root,
      "generated_at" => state.generated_at,
      "entries" => Enum.map(state.entries, &entry_to_json/1)
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp entry_to_json(%Entry{} = e) do
    %{
      "repo" => Atom.to_string(e.repo),
      "repo_path" => e.repo_path,
      "target_app" => Atom.to_string(e.target_app),
      "mix_exs_path" => e.mix_exs_path,
      "mix_exs_before_hash" => e.mix_exs_before_hash,
      "mix_exs_after_hash" => e.mix_exs_after_hash,
      "preimage" => e.preimage,
      "replacement" => e.replacement,
      "operation" => Atom.to_string(e.operation)
    }
  end
end
