defmodule Graft.Validate.Quick do
  @moduledoc """
  Lightweight workspace health checks for `mix graft.validate --quick`.

  Quick validation reads the manifest, checks sibling filesystem shape, asks
  git for local repository metadata, and compares `origin` when the manifest
  declares one. It never runs `mix deps.get`, `mix compile`, or `mix test`.
  """

  alias Graft.{Error, GitRemote, GitState, Manifest, Safety}
  alias Graft.CLI.Errors
  alias Graft.Manifest.Sibling

  defmodule Failure do
    @moduledoc false
    defstruct [:kind, :message, details: %{}]
  end

  defmodule SiblingResult do
    @moduledoc false
    defstruct [:name, :path, :absolute_path, :origin, :status, failures: []]
  end

  defmodule Result do
    @moduledoc false
    defstruct [:root, :target_apps, :passed?, siblings: []]
  end

  @type format :: :text | :json

  @doc """
  Run quick validation for all siblings, or only `target_strings` when given.
  """
  @spec run(Path.t(), [String.t()]) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(root, target_strings \\ []) do
    with {:ok, manifest} <- Manifest.load(root),
         {:ok, selected} <- select_siblings(manifest.siblings, target_strings) do
      git_by_sibling = read_git(selected)
      siblings = Enum.map(selected, &check_sibling(&1, manifest.root, git_by_sibling))

      {:ok,
       %Result{
         root: manifest.root,
         target_apps: Enum.map(selected, & &1.name),
         passed?: Enum.all?(siblings, &(&1.status == :ok)),
         siblings: siblings
       }}
    end
  end

  @doc "Render a quick validation result."
  @spec render(Result.t(), format()) :: String.t()
  def render(%Result{} = result, :text) do
    status = if result.passed?, do: "passed", else: "failed"

    header = [
      "Graft validate --quick",
      "Root: #{result.root}",
      "Siblings: #{length(result.siblings)}",
      "Status: #{status}",
      ""
    ]

    body =
      result.siblings
      |> Enum.flat_map(&sibling_text/1)

    (header ++ body)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  def render(%Result{} = result, :json) do
    %{
      quick: true,
      root: result.root,
      target_apps: Enum.map(result.target_apps, &Atom.to_string/1),
      passed: result.passed?,
      siblings: Enum.map(result.siblings, &sibling_json/1)
    }
    |> Jason.encode!()
  end

  defp select_siblings(siblings, []) do
    {:ok, siblings}
  end

  defp select_siblings(siblings, target_strings) do
    by_name = Map.new(siblings, fn sibling -> {Atom.to_string(sibling.name), sibling} end)

    Enum.reduce_while(target_strings, {:ok, []}, fn target, {:ok, acc} ->
      case Map.fetch(by_name, target) do
        {:ok, sibling} ->
          {:cont, {:ok, [sibling | acc]}}

        :error ->
          {:halt,
           {:error,
            Error.new(
              :validate_target_not_in_workspace,
              "Target app(s) not declared as siblings in graft.exs: [#{target}]",
              %{targets: [target]}
            )}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp read_git(siblings) do
    siblings
    |> Enum.filter(&File.dir?(&1.absolute_path))
    |> Map.new(fn sibling ->
      {sibling.name, GitState.read(sibling.absolute_path, repo: sibling.name)}
    end)
  end

  defp check_sibling(%Sibling{} = sibling, root, git_by_sibling) do
    failures =
      []
      |> check_path_exists(sibling)
      |> check_path_is_directory(sibling)
      |> check_resolved_path_inside_root(sibling, root)
      |> check_mix_exs(sibling)
      |> check_git_repo(sibling, git_by_sibling)
      |> check_origin(sibling, git_by_sibling)

    %SiblingResult{
      name: sibling.name,
      path: sibling.path,
      absolute_path: sibling.absolute_path,
      origin: sibling.origin,
      status: if(failures == [], do: :ok, else: :failed),
      failures: failures
    }
  end

  defp check_path_exists(failures, %Sibling{absolute_path: path}) do
    if File.exists?(path) do
      failures
    else
      failures ++
        [
          failure(:path_missing, "Path does not exist: #{path}", %{path: path})
        ]
    end
  end

  defp check_path_is_directory(failures, %Sibling{absolute_path: path}) do
    cond do
      not File.exists?(path) ->
        failures

      File.dir?(path) ->
        failures

      true ->
        failures ++
          [
            failure(:path_not_directory, "Path exists but is not a directory: #{path}", %{
              path: path
            })
          ]
    end
  end

  defp check_resolved_path_inside_root(failures, %Sibling{absolute_path: path}, root) do
    if File.exists?(path) do
      case Safety.real_path(path) do
        {:ok, resolved} ->
          resolved_root = resolved_root(root)

          case Safety.within_root?(resolved, resolved_root) do
            :ok ->
              failures

            {:error, _} ->
              failures ++
                [
                  failure(
                    :path_escapes_root,
                    "Path resolves outside workspace root: #{path} -> #{resolved}",
                    %{path: path, resolved: resolved, root: resolved_root}
                  )
                ]
          end

        {:error, reason} ->
          failures ++
            [
              failure(:path_unresolvable, "Could not resolve path #{path}: #{inspect(reason)}", %{
                path: path,
                reason: reason
              })
            ]
      end
    else
      failures
    end
  end

  defp check_mix_exs(failures, %Sibling{absolute_path: path}) do
    mix_exs = Path.join(path, "mix.exs")

    cond do
      not File.dir?(path) ->
        failures

      File.regular?(mix_exs) ->
        failures

      true ->
        failures ++
          [
            failure(:mix_exs_missing, "mix.exs does not exist: #{mix_exs}", %{path: mix_exs})
          ]
    end
  end

  defp check_git_repo(failures, %Sibling{absolute_path: path, name: name}, git_by_sibling) do
    cond do
      not File.dir?(path) ->
        failures

      true ->
        git = Map.get(git_by_sibling, name) || GitState.read(path, repo: name)

        cond do
          git.is_git_repo? ->
            failures

          git.error == :git_not_installed ->
            failures ++
              [
                failure(:git_not_installed, "git executable is not installed", %{})
              ]

          true ->
            failures ++
              [
                failure(:git_repo_missing, "Path is not a git repository: #{path}", %{path: path})
              ]
        end
    end
  end

  defp check_origin(failures, %Sibling{origin: nil}, _git_by_sibling), do: failures

  defp check_origin(
         failures,
         %Sibling{absolute_path: path, name: name, origin: expected},
         git_by_sibling
       ) do
    if File.dir?(path) do
      git = Map.get(git_by_sibling, name) || GitState.read(path, repo: name)
      actual = git.origin_url

      cond do
        not git.is_git_repo? ->
          failures

        is_nil(actual) ->
          failures ++
            [
              failure(
                :origin_missing,
                "Expected origin #{expected}, but repo has no origin remote",
                %{
                  expected: expected,
                  actual: nil
                }
              )
            ]

        GitRemote.same?(expected, actual) ->
          failures

        true ->
          failures ++
            [
              failure(
                :origin_mismatch,
                "Expected origin #{expected}, got #{actual}",
                %{expected: expected, actual: actual}
              )
            ]
      end
    else
      failures
    end
  end

  defp failure(kind, message, details) do
    %Failure{kind: kind, message: message, details: details}
  end

  defp resolved_root(root) do
    case Safety.real_path(root) do
      {:ok, resolved} -> resolved
      {:error, _} -> root
    end
  end

  defp sibling_text(%SiblingResult{status: :ok} = sibling) do
    [
      "#{sibling.name} [ok]",
      "  path: #{sibling.path}",
      ""
    ]
  end

  defp sibling_text(%SiblingResult{} = sibling) do
    [
      "#{sibling.name} [failed]",
      "  path: #{sibling.path}"
      | Enum.map(sibling.failures, fn failure ->
          "  - #{failure.kind}: #{failure.message}"
        end)
    ] ++ [""]
  end

  defp sibling_json(%SiblingResult{} = sibling) do
    %{
      name: Atom.to_string(sibling.name),
      path: sibling.path,
      absolute_path: sibling.absolute_path,
      origin: sibling.origin,
      status: Atom.to_string(sibling.status),
      failures:
        Enum.map(sibling.failures, fn failure ->
          %{
            kind: Atom.to_string(failure.kind),
            message: failure.message,
            details: Errors.jsonable(failure.details)
          }
        end)
    }
  end
end
