defmodule Graft.Remove do
  @moduledoc """
  Remove sibling entries from `graft.exs`, optionally deleting their directories.

  Manifest removal is the default operation. Filesystem deletion only happens
  when the caller passes `delete: true`, and dirty git repositories are refused
  unless `force: true` is also supplied.
  """

  alias Graft.{Error, GitState, Manifest, Safety}
  alias Graft.CLI.Errors
  alias Graft.Manifest.Sibling

  defmodule Outcome do
    @moduledoc false
    defstruct [
      :name,
      :path,
      :absolute_path,
      :status,
      :message,
      delete?: false,
      dirty?: false,
      failures: []
    ]
  end

  defmodule Failure do
    @moduledoc false
    defstruct [:kind, :message, details: %{}]
  end

  defmodule Result do
    @moduledoc false
    defstruct [
      :root,
      :dry_run?,
      :delete?,
      :force?,
      :applied?,
      :passed?,
      outcomes: []
    ]
  end

  @type format :: :text | :json

  @doc """
  Remove `target_strings` from the manifest rooted at `root`.
  """
  @spec remove([String.t()], Path.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Result.t() | Error.t()}
  def remove(target_strings, root, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    delete? = Keyword.get(opts, :delete, false)
    force? = Keyword.get(opts, :force, false)

    with {:ok, manifest} <- Manifest.load(root),
         {:ok, targets} <- resolve_targets(manifest, target_strings) do
      outcomes = Enum.map(targets, &plan_outcome(&1, manifest.root, delete?, force?))
      passed? = Enum.all?(outcomes, &(&1.status != :error))

      planned = %Result{
        root: manifest.root,
        dry_run?: dry_run?,
        delete?: delete?,
        force?: force?,
        applied?: false,
        passed?: passed?,
        outcomes: outcomes
      }

      cond do
        not passed? ->
          {:error, planned}

        dry_run? ->
          {:ok, planned}

        true ->
          apply_remove(manifest, targets, planned)
      end
    end
  end

  @doc "Render a remove result."
  @spec render(Result.t(), format()) :: String.t()
  def render(%Result{} = result, :text) do
    mode =
      cond do
        not result.passed? -> "refused"
        result.dry_run? -> "dry-run"
        result.applied? -> "applied"
        true -> "planned"
      end

    header = [
      "Graft remove (#{mode})",
      "Root: #{result.root}",
      ""
    ]

    body = Enum.flat_map(result.outcomes, &outcome_text/1)

    (header ++ body)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  def render(%Result{} = result, :json) do
    %{
      operation: "remove",
      root: result.root,
      dry_run: result.dry_run?,
      delete: result.delete?,
      force: result.force?,
      applied: result.applied?,
      passed: result.passed?,
      outcomes: Enum.map(result.outcomes, &outcome_json/1)
    }
    |> Jason.encode!()
  end

  defp resolve_targets(_manifest, []) do
    {:error,
     Error.new(
       :remove_target_required,
       "At least one sibling name is required",
       %{}
     )}
  end

  defp resolve_targets(%Manifest{siblings: siblings}, target_strings) do
    by_name = Map.new(siblings, fn sibling -> {Atom.to_string(sibling.name), sibling} end)

    Enum.reduce_while(target_strings, {:ok, []}, fn target, {:ok, acc} ->
      case Map.fetch(by_name, target) do
        {:ok, sibling} ->
          {:cont, {:ok, [sibling | acc]}}

        :error ->
          {:halt,
           {:error,
            Error.new(
              :remove_target_not_in_manifest,
              "Sibling #{inspect(target)} is not declared in graft.exs",
              %{target: target}
            )}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp plan_outcome(%Sibling{} = sibling, root, delete?, force?) do
    failures =
      []
      |> check_delete_path_safety(sibling, root, delete?)
      |> check_dirty_repo(sibling, delete?, force?)

    status = if failures == [], do: :planned, else: :error

    %Outcome{
      name: sibling.name,
      path: sibling.path,
      absolute_path: sibling.absolute_path,
      status: status,
      message: planned_message(sibling, delete?),
      delete?: delete?,
      dirty?: dirty_repo?(sibling),
      failures: failures
    }
  end

  defp check_delete_path_safety(failures, _sibling, _root, false), do: failures

  defp check_delete_path_safety(failures, %Sibling{absolute_path: path}, root, true) do
    with :ok <- Safety.within_root?(path, root),
         {:exists, true} <- {:exists, File.exists?(path)},
         {:ok, resolved} <- Safety.real_path(path),
         :ok <- Safety.within_root?(resolved, resolved_root(root)) do
      failures
    else
      {:exists, false} ->
        failures

      {:error, %Error{} = err} ->
        failures ++ [failure(err.kind, err.message, err.details)]

      {:error, reason} ->
        failures ++
          [
            failure(:remove_path_unresolvable, "Could not resolve #{path}: #{inspect(reason)}", %{
              path: path,
              reason: reason
            })
          ]
    end
  end

  defp check_dirty_repo(failures, _sibling, false, _force?), do: failures
  defp check_dirty_repo(failures, _sibling, true, true), do: failures

  defp check_dirty_repo(failures, %Sibling{} = sibling, true, false) do
    if dirty_repo?(sibling) do
      failures ++
        [
          failure(
            :remove_dirty_repo,
            "Refusing to delete dirty repo #{sibling.name}; commit or stash changes, or pass --force",
            %{name: sibling.name, path: sibling.absolute_path}
          )
        ]
    else
      failures
    end
  end

  defp dirty_repo?(%Sibling{absolute_path: path, name: name}) do
    File.dir?(path) and
      case GitState.read(path, repo: name) do
        %GitState{is_git_repo?: true, dirty?: dirty?} -> dirty?
        _ -> false
      end
  end

  defp resolved_root(root) do
    case Safety.real_path(root) do
      {:ok, resolved} -> resolved
      {:error, _} -> root
    end
  end

  defp planned_message(%Sibling{} = sibling, false) do
    "remove #{sibling.name} from graft.exs"
  end

  defp planned_message(%Sibling{} = sibling, true) do
    "remove #{sibling.name} from graft.exs and delete #{sibling.absolute_path}"
  end

  defp apply_remove(%Manifest{} = manifest, targets, %Result{} = planned) do
    target_names = MapSet.new(targets, & &1.name)
    remaining = Enum.reject(manifest.siblings, &MapSet.member?(target_names, &1.name))

    with :ok <- Manifest.write(manifest.source_path, manifest.root_declared, remaining),
         :ok <- maybe_delete_targets(targets, planned.delete?) do
      outcomes =
        Enum.map(planned.outcomes, fn outcome ->
          %{outcome | status: :removed, message: applied_message(outcome)}
        end)

      {:ok, %{planned | applied?: true, outcomes: outcomes}}
    end
  end

  defp maybe_delete_targets(_targets, false), do: :ok

  defp maybe_delete_targets(targets, true) do
    Enum.reduce_while(targets, :ok, fn sibling, :ok ->
      case delete_path(sibling.absolute_path) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = err} -> {:halt, {:error, err}}
      end
    end)
  end

  defp delete_path(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _paths} ->
          :ok

        {:error, reason, failed_path} ->
          {:error,
           Error.new(
             :remove_delete_failed,
             "Failed to delete #{failed_path}: #{inspect(reason)}",
             %{path: failed_path, reason: reason}
           )}
      end
    else
      :ok
    end
  end

  defp applied_message(%Outcome{delete?: false, name: name}), do: "removed #{name} from graft.exs"

  defp applied_message(%Outcome{delete?: true, name: name, absolute_path: path}) do
    "removed #{name} from graft.exs and deleted #{path}"
  end

  defp failure(kind, message, details) do
    %Failure{kind: kind, message: message, details: details}
  end

  defp outcome_text(%Outcome{status: :error} = outcome) do
    [
      "#{outcome.name} [error]",
      "  path: #{outcome.path}"
      | Enum.map(outcome.failures, fn failure ->
          "  - #{failure.kind}: #{failure.message}"
        end)
    ] ++ [""]
  end

  defp outcome_text(%Outcome{} = outcome) do
    [
      "#{outcome.name} [#{outcome.status}]",
      "  #{outcome.message}",
      ""
    ]
  end

  defp outcome_json(%Outcome{} = outcome) do
    %{
      name: Atom.to_string(outcome.name),
      path: outcome.path,
      absolute_path: outcome.absolute_path,
      status: Atom.to_string(outcome.status),
      message: outcome.message,
      delete: outcome.delete?,
      dirty: outcome.dirty?,
      failures:
        Enum.map(outcome.failures, fn failure ->
          %{
            kind: Atom.to_string(failure.kind),
            message: failure.message,
            details: Errors.jsonable(failure.details)
          }
        end)
    }
  end
end
