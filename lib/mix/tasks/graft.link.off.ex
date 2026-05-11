defmodule Mix.Tasks.Graft.Link.Off do
  @shortdoc "Restore sibling-repo deps from `.graft/state.json`"

  @moduledoc """
  Revert a prior `mix graft.link.on` rewrite by restoring literal
  preimages recorded in `.graft/state.json`.

      mix graft.link.off req_llm --dry-run
      mix graft.link.off req_llm
      mix graft.link.off req_llm --json

  Restoration is always *literal* — Off never reasons about AST. The
  recorded `preimage` (original Hex/Git tuple) replaces the `replacement`
  (path-link tuple currently in the consumer's `mix.exs`). Hash
  verification gates every write; mismatches abort before mutation.

  No git, no `mix deps.unlock`, no `mix deps.get`.
  """

  use Mix.Task

  alias Graft.{Error, State, Workspace}
  alias Graft.CLI.Errors
  alias Graft.Link.Off.{Plan, Runner}
  alias Graft.Link.Off.Plan.Render

  @switches [json: :boolean, dry_run: :boolean, root: :string]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:error, output, :stdout} ->
        Mix.shell().info(output)
        exit({:shutdown, 1})

      {:error, output, :stderr} ->
        Mix.shell().error(output)
        exit({:shutdown, 1})
    end
  end

  @spec execute([String.t()]) :: {:ok, String.t()} | {:error, String.t(), :stdout | :stderr}
  def execute(argv) do
    case parse_args(argv) do
      {:ok, opts, target_strings} ->
        format = if opts[:json], do: :json, else: :text

        cond do
          target_strings == [] ->
            {:error, "graft.link.off: at least one target app is required", :stderr}

          Keyword.get(opts, :dry_run, false) ->
            run_dry_run(opts, target_strings, format)

          true ->
            run_apply(opts, target_strings, format)
        end

      {:error, msg} ->
        {:error, "graft.link.off: #{msg}", :stderr}
    end
  end

  defp parse_args(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    {:ok, opts, positional}
  rescue
    e in OptionParser.ParseError ->
      {:error, Exception.message(e)}
  end

  ## ─── Dry-run / apply ────────────────────────────────────────────────

  defp run_dry_run(opts, target_strings, format) do
    case build_plan(opts, target_strings) do
      {:ok, plan} -> {:ok, Render.render(plan, format)}
      {:error, %Error{} = err} -> format_error(err, format)
    end
  end

  defp run_apply(opts, target_strings, format) do
    with {:ok, plan} <- build_plan(opts, target_strings),
         {:ok, result} <- Runner.run(plan) do
      {:ok, Render.render_applied(plan, result, format)}
    else
      {:error, %Error{} = err} -> format_error(err, format)
    end
  end

  defp build_plan(opts, target_strings) do
    root = opts[:root] || File.cwd!()

    with {:ok, snapshot} <- Workspace.snapshot(root),
         {:ok, state} <- load_state(root),
         {:ok, targets} <- resolve_targets(target_strings, snapshot, state),
         {:ok, plan} <- Plan.build(snapshot, state, targets) do
      {:ok, plan}
    end
  end

  defp load_state(root) do
    case State.load(root) do
      {:ok, state} ->
        {:ok, state}

      {:error, %Error{kind: :state_io_error} = err} ->
        {:error,
         Error.new(
           :off_state_missing,
           "No link state to restore at #{State.state_path(root)} — run `mix graft.link.on` first",
           Map.put(err.details, :cause, err.kind)
         )}

      {:error, %Error{}} = err ->
        err
    end
  end

  # Only resolve target strings against atoms already declared either
  # as workspace siblings or as recorded `target_app`s in state. We
  # never call `String.to_atom/1`.
  defp resolve_targets(strings, snapshot, state) do
    sibling_pairs = Enum.map(snapshot.repos, fn r -> {Atom.to_string(r.name), r.name} end)

    state_pairs =
      Enum.map(state.entries, fn e -> {Atom.to_string(e.target_app), e.target_app} end)

    by_name = Map.new(sibling_pairs ++ state_pairs)

    Enum.reduce_while(strings, {:ok, []}, fn s, {:ok, acc} ->
      case Map.fetch(by_name, s) do
        {:ok, atom} ->
          {:cont, {:ok, [atom | acc]}}

        :error ->
          {:halt,
           {:error,
            Error.new(
              :off_target_not_in_state,
              "Target app(s) not declared as siblings or recorded in state.json: [#{s}]",
              %{targets: [s]}
            )}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp format_error(%Error{} = err, format), do: Errors.format(err, format, "graft.link.off")
end
