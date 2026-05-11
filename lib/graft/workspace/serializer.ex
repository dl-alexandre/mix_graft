defmodule Graft.Workspace.Serializer do
  @moduledoc """
  Serializes and deserializes `Graft.Workspace` snapshots.

  Every snapshot is versioned (`schema_version`). The serializer handles
  migration between schema versions transparently on load.

  ## Contract

  * Snapshots encode to deterministic JSON — same bytes for same logical state.
  * Atoms become strings, paths become strings, DateTimes become ISO8601.
  * Unknown fields on decode are preserved in a `__extra__` map for forward
    compatibility (future schema versions can read old snapshots).
  * Decode failures return structured `Graft.Error{}`, not exceptions.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.{Repo, Dependency, Link, Topology}
  alias Graft.GitState

  @current_schema_version 1

  @doc """
  Encode a workspace snapshot to a JSON string.
  """
  @spec to_json(Workspace.t()) :: String.t()
  def to_json(%Workspace{} = snapshot) do
    snapshot
    |> to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Decode a JSON string into a workspace snapshot.

  Handles schema migration. Returns `{:ok, snapshot}` or `{:error, reason}`.
  """
  @spec from_json(String.t()) :: {:ok, Workspace.t()} | {:error, Error.t()}
  def from_json(json) when is_binary(json) do
    with {:ok, raw_map} <- decode_json(json),
         {:ok, version} <- extract_schema_version(raw_map),
         {:ok, migrated} <- migrate_to_current(raw_map, version) do
      build_snapshot(migrated)
    end
  end

  @doc """
  Persist a snapshot to disk atomically.

  Writes to a temp file and renames — POSIX-atomic within a filesystem.
  """
  @spec save(Path.t(), Workspace.t()) :: :ok | {:error, Error.t()}
  def save(path, %Workspace{} = snapshot) do
    json = to_json(snapshot)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        {:error,
         Error.new(
           :workspace_io_error,
           "Failed to write snapshot to #{path}: #{:file.format_error(reason)}",
           %{path: path, reason: reason}
         )}
    end
  end

  @doc """
  Load a snapshot from disk.
  """
  @spec load(Path.t()) :: {:ok, Workspace.t()} | {:error, Error.t()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, json} ->
        from_json(json)

      {:error, reason} ->
        {:error,
         Error.new(
           :workspace_io_error,
           "Failed to read snapshot from #{path}: #{:file.format_error(reason)}",
           %{path: path, reason: reason}
         )}
    end
  end

  ## ─── Encoding ───────────────────────────────────────────────────────

  defp to_map(%Workspace{} = ws) do
    %{
      "id" => ws.id,
      "schema_version" => ws.schema_version,
      "root" => ws.root,
      "generated_at" => DateTime.to_iso8601(ws.generated_at),
      "repos" => Enum.map(ws.repos, &repo_to_map/1),
      "deps" => Enum.map(ws.deps, &dep_to_map/1),
      "links" => Enum.map(ws.links, &link_to_map/1),
      "topology" => topology_to_map(ws.topology),
      "git" => Enum.map(ws.git, &git_state_to_map/1),
      "prs" => Enum.map(ws.prs, &pr_to_map/1),
      "health" => Enum.map(ws.health, &health_to_map/1),
      "diagnostics" => Enum.map(ws.diagnostics, &diagnostic_to_map/1),
      "validate_result" => validate_result_to_map(ws.validate_result)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp repo_to_map(%Repo{} = r) do
    %{
      "name" => Atom.to_string(r.name),
      "path" => r.path,
      "absolute_path" => r.absolute_path,
      "exists?" => r.exists?,
      "has_mix_exs?" => r.has_mix_exs?
    }
  end

  defp dep_to_map(%Dependency{} = d) do
    %{
      "repo" => Atom.to_string(d.repo),
      "app" => Atom.to_string(d.app),
      "raw" => d.raw,
      "source" => Atom.to_string(d.source)
    }
  end

  defp link_to_map(%Link{} = l) do
    %{
      "repo" => Atom.to_string(l.repo),
      "dep" => Atom.to_string(l.dep),
      "mix_exs_sha256_before" => l.mix_exs_sha256_before,
      "mix_exs_sha256_after" => l.mix_exs_sha256_after,
      "preimage" => l.preimage,
      "replacement" => l.replacement
    }
  end

  defp topology_to_map(nil), do: nil

  defp topology_to_map(%Topology{} = t) do
    %{
      "consumers" => map_atom_keys_to_strings(t.consumers),
      "providers" => map_atom_keys_to_strings(t.providers),
      "transitive_dependents" =>
        Map.new(t.transitive_dependents, fn {k, v} ->
          {Atom.to_string(k), Enum.to_list(v)}
        end),
      "topological_order" => Enum.map(t.topological_order, &Atom.to_string/1),
      "external_apps" => Enum.map(t.external_apps, &Atom.to_string/1),
      "cyclic?" => t.cyclic?
    }
  end

  defp git_state_to_map(%GitState{} = g) do
    %{
      "repo" => if(g.repo, do: Atom.to_string(g.repo), else: nil),
      "repo_path" => g.repo_path,
      "is_git_repo?" => g.is_git_repo?,
      "branch" => g.branch,
      "detached_head?" => g.detached_head?,
      "head_sha" => g.head_sha,
      "upstream" => g.upstream,
      "ahead" => g.ahead,
      "behind" => g.behind,
      "dirty?" => g.dirty?,
      "in_progress" => Atom.to_string(g.in_progress),
      "error" => if(g.error, do: Atom.to_string(g.error), else: nil)
    }
  end

  # TODO when PR type stabilizes
  defp pr_to_map(_pr), do: %{}
  # TODO when HealthIssue type stabilizes
  defp health_to_map(_h), do: %{}
  # TODO when Diagnostic type stabilizes
  defp diagnostic_to_map(_d), do: %{}
  defp validate_result_to_map(nil), do: nil
  # Placeholder
  defp validate_result_to_map(vr), do: Jason.encode!(vr)

  defp map_atom_keys_to_strings(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  ## ─── Decoding ───────────────────────────────────────────────────────

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        {:ok, map}

      {:error, e} ->
        {:error,
         Error.new(
           :workspace_invalid_json,
           "Failed to parse workspace snapshot: #{Exception.message(e)}"
         )}
    end
  end

  defp extract_schema_version(map) when is_map(map) do
    case Map.fetch(map, "schema_version") do
      {:ok, v} when is_integer(v) and v > 0 ->
        {:ok, v}

      {:ok, v} ->
        {:error,
         Error.new(
           :workspace_invalid_schema,
           "Invalid schema version: #{inspect(v)}",
           %{schema_version: v}
         )}

      :error ->
        {:error,
         Error.new(
           :workspace_invalid_schema,
           "Missing schema_version field"
         )}
    end
  end

  defp migrate_to_current(map, version) when version == @current_schema_version do
    {:ok, map}
  end

  defp migrate_to_current(_map, version) do
    {:error,
     Error.new(
       :workspace_unsupported_schema,
       "Schema version #{version} is not supported (current: #{@current_schema_version}). " <>
         "Migration path not yet implemented.",
       %{version: version, current: @current_schema_version}
     )}
  end

  defp build_snapshot(map) when is_map(map) do
    with {:ok, id} <- fetch_string(map, "id"),
         {:ok, root} <- fetch_string(map, "root"),
         {:ok, generated_at} <- fetch_datetime(map, "generated_at"),
         {:ok, repos} <- fetch_list_of(map, "repos", &build_repo/1),
         {:ok, deps} <- fetch_list_of(map, "deps", &build_dep/1),
         {:ok, topology} <- fetch_optional(map, "topology", &build_topology/1),
         {:ok, git} <- fetch_list_of(map, "git", &build_git_state/1) do
      {:ok,
       %Workspace{
         id: id,
         schema_version: @current_schema_version,
         root: root,
         generated_at: generated_at,
         repos: repos,
         deps: deps,
         topology: topology,
         git: git
         # Other fields are defaults
       }}
    end
  end

  ## ─── Field helpers ────────────────────────────────────────────────

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, s} when is_binary(s) ->
        {:ok, s}

      {:ok, other} ->
        {:error,
         Error.new(:workspace_invalid_field, "#{key} must be a string, got: #{inspect(other)}")}

      :error ->
        {:error, Error.new(:workspace_invalid_field, "Missing required field: #{key}")}
    end
  end

  defp fetch_datetime(map, key) do
    with {:ok, s} <- fetch_string(map, key) do
      case DateTime.from_iso8601(s) do
        {:ok, dt, _} ->
          {:ok, dt}

        {:error, _} ->
          {:error,
           Error.new(:workspace_invalid_field, "#{key} is not a valid ISO8601 datetime: #{s}")}
      end
    end
  end

  defp fetch_list_of(map, key, builder) do
    case Map.fetch(map, key) do
      {:ok, list} when is_list(list) ->
        Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
          case builder.(item) do
            {:ok, built} -> {:cont, {:ok, [built | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          err -> err
        end

      {:ok, other} ->
        {:error,
         Error.new(:workspace_invalid_field, "#{key} must be a list, got: #{inspect(other)}")}

      :error ->
        # Optional lists default to empty
        {:ok, []}
    end
  end

  defp fetch_optional(map, key, builder) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> builder.(value)
      :error -> {:ok, nil}
    end
  end

  ## ─── Builders ───────────────────────────────────────────────────────

  defp build_repo(map) when is_map(map) do
    with {:ok, name} <- fetch_atom(map, "name"),
         {:ok, path} <- fetch_string(map, "path"),
         {:ok, absolute_path} <- fetch_string(map, "absolute_path"),
         exists? <- Map.get(map, "exists?", false),
         has_mix_exs? <- Map.get(map, "has_mix_exs?", false) do
      {:ok,
       %Repo{
         name: name,
         path: path,
         absolute_path: absolute_path,
         exists?: exists?,
         has_mix_exs?: has_mix_exs?
       }}
    end
  end

  defp build_dep(map) when is_map(map) do
    with {:ok, repo} <- fetch_atom(map, "repo"),
         {:ok, app} <- fetch_atom(map, "app"),
         {:ok, raw} <- fetch_string(map, "raw"),
         {:ok, source} <- fetch_atom(map, "source") do
      {:ok,
       %Dependency{
         repo: repo,
         app: app,
         raw: raw,
         source: source
       }}
    end
  end

  defp build_topology(map) when is_map(map) do
    {:ok,
     %Topology{
       consumers: map_string_keys_to_atoms(Map.get(map, "consumers", %{})),
       providers: map_string_keys_to_atoms(Map.get(map, "providers", %{})),
       transitive_dependents:
         Map.new(Map.get(map, "transitive_dependents", %{}), fn {k, v} ->
           {String.to_existing_atom(k), MapSet.new(v)}
         end),
       topological_order:
         Map.get(map, "topological_order", [])
         |> Enum.map(&String.to_existing_atom/1),
       external_apps:
         Map.get(map, "external_apps", [])
         |> Enum.map(&String.to_existing_atom/1),
       cyclic?: Map.get(map, "cyclic?", false)
     }}
  rescue
    ArgumentError ->
      {:error,
       Error.new(
         :workspace_invalid_field,
         "Topology references unknown atoms — load workspace before snapshot"
       )}
  end

  defp build_git_state(map) when is_map(map) do
    {:ok,
     %GitState{
       repo: map |> Map.get("repo") |> maybe_atom(),
       repo_path: Map.get(map, "repo_path"),
       is_git_repo?: Map.get(map, "is_git_repo?", false),
       branch: Map.get(map, "branch"),
       detached_head?: Map.get(map, "detached_head?", false),
       head_sha: Map.get(map, "head_sha"),
       upstream: Map.get(map, "upstream"),
       ahead: Map.get(map, "ahead", 0),
       behind: Map.get(map, "behind", 0),
       dirty?: Map.get(map, "dirty?", false),
       in_progress:
         map
         |> Map.get("in_progress", "none")
         |> String.to_existing_atom(),
       error:
         map
         |> Map.get("error")
         |> maybe_existing_atom()
     }}
  rescue
    ArgumentError ->
      {:error, Error.new(:workspace_invalid_field, "GitState references unknown atoms")}
  end

  ## ─── Atom helpers ───────────────────────────────────────────────────

  defp fetch_atom(map, key) do
    with {:ok, s} <- fetch_string(map, key) do
      try do
        {:ok, String.to_existing_atom(s)}
      rescue
        ArgumentError ->
          {:error,
           Error.new(
             :workspace_unknown_atom,
             "Field #{key} references unknown atom: #{s}. Load workspace before snapshot.",
             %{key: key, value: s}
           )}
      end
    end
  end

  defp maybe_atom(nil), do: nil
  defp maybe_atom(s) when is_binary(s), do: String.to_atom(s)

  defp maybe_existing_atom(nil), do: nil

  defp maybe_existing_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp map_string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {String.to_existing_atom(k), v}
    end)
  end
end
