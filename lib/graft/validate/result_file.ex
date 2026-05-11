defmodule Graft.Validate.ResultFile do
  @moduledoc """
  Persists and reads `.graft/validate.result.json` — the durable
  evidence file produced by `mix graft.validate`.

  ## Contract

    * **Written on every completed run**, pass or fail. Dry-runs do not
      write. The file is observational evidence: it records what
      happened, not what should happen next.
    * **Atomic write.** Same write-temp + rename pattern Graft uses
      elsewhere. A killed save either leaves the file untouched or
      replaces it whole.
    * **Lean schema.** Verdict, per-repo status, headline first
      failure, and a `mix.exs` hash fingerprint per affected repo.
      Full command transcripts live in `.graft/validate.log`.
    * **Versioned.** `version: 1` today. Future versions bump and add
      a `migrate/1`-style dispatcher; older files are explicitly
      rejected rather than silently misread.
    * **Corruption is not fatal to the workspace.** If the file is
      unreadable, `Workspace.snapshot/1` treats `validate_result` as
      `nil` — consumers see "no validation recorded" rather than
      "workspace is broken." Trust state (`.graft/state.json`) gets
      stricter treatment because it gates mutation; this file does
      not.
    * **Staleness check** via `stale?/2` rehashes each fingerprinted
      `mix.exs` and compares. A `passed` result with a stale
      fingerprint is no longer trustworthy.
  """

  alias Graft.{Error, State, Workspace}
  alias Graft.Validate.ResultFile.Persisted
  alias Graft.Validate.Plan
  alias Graft.Validate.Runner.{RepoFailure, RepoOutcome, Result}

  @schema_version 1
  @dir ".graft"
  @file_name "validate.result.json"
  @temp_suffix ".graft.tmp"

  @doc "Conventional path under `workspace_root`."
  @spec path(Path.t()) :: Path.t()
  def path(workspace_root), do: Path.join([workspace_root, @dir, @file_name])

  @doc """
  Persist `result` (the runner's in-memory `%Result{}`) under
  `workspace_root/.graft/validate.result.json`. The plan supplies
  the affected-repo paths used to fingerprint `mix.exs` contents.

  Returns `:ok` or `{:error, %Graft.Error{}}`. Failures are
  observational; the validate run itself is not invalidated.
  """
  @spec save(Path.t(), Plan.t(), Result.t()) :: :ok | {:error, Error.t()}
  def save(workspace_root, %Plan{} = plan, %Result{} = result) do
    payload = build_payload(workspace_root, plan, result)
    target = path(workspace_root)
    tmp = target <> @temp_suffix

    with :ok <- ensure_dir(Path.dirname(target)),
         :ok <- write_temp(tmp, payload),
         :ok <- rename(tmp, target) do
      :ok
    else
      {:error, %Error{}} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  @doc """
  Load the persisted result. `{:error, :validate_result_missing}` is
  semantically distinct from `:validate_result_unreadable` — callers
  who treat "no result yet" as a normal state branch on the former.
  """
  @spec load(Path.t()) :: {:ok, Persisted.t()} | {:error, Error.t()}
  def load(workspace_root) when is_binary(workspace_root) do
    file_path = path(workspace_root)

    with {:ok, raw} <- read_file(file_path),
         {:ok, decoded} <- decode(raw, file_path),
         {:ok, persisted} <- validate(decoded, file_path) do
      {:ok, persisted}
    end
  end

  @doc """
  Returns `true` if any fingerprinted `mix.exs` differs from disk, or
  if a fingerprinted repo is no longer present. A passing run whose
  fingerprint matches every current `mix.exs` is fresh; anything else
  is stale.
  """
  @spec stale?(Workspace.t(), Persisted.t()) :: boolean()
  def stale?(%Workspace{} = workspace, %Persisted{fingerprint: fingerprint}) do
    repos_by_name = Map.new(workspace.repos, &{&1.name, &1})

    Enum.any?(fingerprint, fn {repo, expected_hash} ->
      case Map.get(repos_by_name, repo) do
        nil ->
          true

        repo_struct ->
          case File.read(Path.join(repo_struct.absolute_path, "mix.exs")) do
            {:ok, contents} -> State.hash_contents(contents) != expected_hash
            {:error, _} -> true
          end
      end
    end)
  end

  ## ─── Encode ────────────────────────────────────────────────────────

  defp build_payload(workspace_root, %Plan{} = plan, %Result{} = result) do
    fingerprint = compute_fingerprint(plan)

    %{
      "version" => @schema_version,
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "workspace_root" => workspace_root,
      "target_apps" => Enum.map(plan.target_apps, &Atom.to_string/1),
      "affected_repos" => Enum.map(result.affected_repos, &Atom.to_string/1),
      "passed" => result.passed?,
      "passed_count" => result.passed_count,
      "failed_count" => result.failed_count,
      "skipped_count" => result.skipped_count,
      "duration_ms" => result.duration_ms,
      "first_failure" => encode_first_failure(result.first_failure),
      "repo_statuses" => encode_repo_statuses(result.outcomes),
      "fingerprint" => Map.new(fingerprint, fn {k, v} -> {Atom.to_string(k), v} end),
      "log_path" => result.log_path
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp compute_fingerprint(%Plan{steps: steps}) do
    Enum.reduce(steps, %{}, fn step, acc ->
      case File.read(Path.join(step.repo_path, "mix.exs")) do
        {:ok, contents} -> Map.put(acc, step.repo, State.hash_contents(contents))
        {:error, _} -> acc
      end
    end)
  end

  defp encode_first_failure(nil), do: nil

  defp encode_first_failure(%RepoFailure{} = f) do
    %{
      "repo" => Atom.to_string(f.repo),
      "command_kind" => Atom.to_string(f.command_kind),
      "failure_category" => Atom.to_string(f.failure_category || :unknown),
      "summary" => f.summary
    }
  end

  defp encode_repo_statuses(outcomes) do
    Map.new(outcomes, fn %RepoOutcome{repo: r, status: s} ->
      {Atom.to_string(r), Atom.to_string(s)}
    end)
  end

  ## ─── Decode + validate ────────────────────────────────────────────

  defp read_file(file_path) do
    case File.read(file_path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error,
         Error.new(
           :validate_result_missing,
           "No validate result at #{file_path} — run `mix graft.validate` first",
           %{path: file_path, reason: :enoent}
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Failed to read #{file_path}: #{:file.format_error(reason)}",
           %{path: file_path, reason: reason}
         )}
    end
  end

  defp decode(raw, file_path) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "#{file_path} must decode to a JSON object, got: #{inspect(other)}",
           %{path: file_path}
         )}

      {:error, %Jason.DecodeError{} = e} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Failed to parse #{file_path}: #{Exception.message(e)}",
           %{path: file_path}
         )}
    end
  end

  defp validate(decoded, file_path) do
    with {:ok, version} <- fetch_field(decoded, "version", file_path),
         :ok <- check_version(version, file_path) do
      {:ok,
       %Persisted{
         version: version,
         generated_at: Map.get(decoded, "generated_at"),
         workspace_root: Map.get(decoded, "workspace_root"),
         target_apps: decode_atoms(Map.get(decoded, "target_apps", []), file_path),
         affected_repos: decode_atoms(Map.get(decoded, "affected_repos", []), file_path),
         passed?: Map.get(decoded, "passed", false),
         passed_count: Map.get(decoded, "passed_count", 0),
         failed_count: Map.get(decoded, "failed_count", 0),
         skipped_count: Map.get(decoded, "skipped_count", 0),
         duration_ms: Map.get(decoded, "duration_ms", 0),
         first_failure: decode_first_failure(Map.get(decoded, "first_failure"), file_path),
         repo_statuses: decode_repo_statuses(Map.get(decoded, "repo_statuses", %{}), file_path),
         fingerprint: decode_fingerprint(Map.get(decoded, "fingerprint", %{}), file_path),
         log_path: Map.get(decoded, "log_path")
       }}
    end
  end

  defp fetch_field(decoded, key, file_path) do
    case Map.fetch(decoded, key) do
      {:ok, v} ->
        {:ok, v}

      :error ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Missing required field #{inspect(key)} in #{file_path}",
           %{path: file_path, key: key}
         )}
    end
  end

  defp check_version(@schema_version, _), do: :ok

  defp check_version(other, file_path) do
    {:error,
     Error.new(
       :validate_result_unreadable,
       "Unsupported validate-result schema version #{inspect(other)} in #{file_path} (expected #{@schema_version})",
       %{path: file_path, got: other, expected: @schema_version}
     )}
  end

  defp decode_atoms(list, _file_path) when is_list(list) do
    Enum.flat_map(list, fn
      s when is_binary(s) ->
        try do
          [String.to_existing_atom(s)]
        rescue
          ArgumentError -> []
        end

      _ ->
        []
    end)
  end

  defp decode_atoms(_, _), do: []

  defp decode_first_failure(nil, _), do: nil

  defp decode_first_failure(%{} = m, _file_path) do
    %{
      repo: safe_atom(Map.get(m, "repo")),
      command_kind: safe_atom(Map.get(m, "command_kind")),
      failure_category: safe_atom(Map.get(m, "failure_category")),
      summary: Map.get(m, "summary")
    }
  end

  defp decode_first_failure(_, _), do: nil

  defp decode_repo_statuses(map, _file_path) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_atom(k), safe_atom(v)} end)
    |> Enum.reject(fn {k, _} -> is_nil(k) end)
    |> Map.new()
  end

  defp decode_repo_statuses(_, _), do: %{}

  defp decode_fingerprint(map, _file_path) when is_map(map) do
    Map.new(map, fn {k, v} -> {safe_atom(k), v} end)
    |> Enum.reject(fn {k, _} -> is_nil(k) end)
    |> Map.new()
  end

  defp decode_fingerprint(_, _), do: %{}

  defp safe_atom(nil), do: nil

  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_), do: nil

  ## ─── IO helpers ───────────────────────────────────────────────────

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Failed to create #{dir}: #{:file.format_error(reason)}",
           %{path: dir, reason: reason}
         )}
    end
  end

  defp write_temp(tmp, contents) do
    case File.write(tmp, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Failed to write #{tmp}: #{:file.format_error(reason)}",
           %{path: tmp, reason: reason}
         )}
    end
  end

  defp rename(tmp, target) do
    case File.rename(tmp, target) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(
           :validate_result_unreadable,
           "Failed to rename #{tmp} → #{target}: #{:file.format_error(reason)}",
           %{from: tmp, to: target, reason: reason}
         )}
    end
  end
end
