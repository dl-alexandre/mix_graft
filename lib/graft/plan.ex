defmodule Graft.Plan do
  @moduledoc """
  A plan to transition a workspace from one snapshot to another.

  ## Model

  A plan is:

  * `current` — the workspace snapshot before the operation
  * `desired` — the workspace snapshot after the operation (computed, not observed)
  * `operations` — ordered steps to effect the transition
  * `rollback` — ordered steps to revert if anything fails
  * `preconditions` — assertions that must hold before execution

  ## Philosophy

  Plans are **declarative**. They describe desired state, not imperative
  commands. Execution is the job of `Graft.Runner` (not yet implemented).

  ## Source

  Plans can be built from:

  * A `Workspace.Diff` — "here's what changed, make it so"
  * A direct manipulation — `link.on jason` produces a desired snapshot with links added
  * A template — "workspace with all deps resolved to paths"

  ## Invariants

  * Every operation in a plan has a unique index.
  * Dependencies between operations are explicit (`depends_on`).
  * Preconditions reference `current` only, never `desired`.
  * Rollback steps are the inverse of forward steps, in reverse order.
  """

  alias Graft.{Error, Workspace}
  alias Graft.Workspace.Diff

  defmodule Operation do
    @moduledoc "A single step in a graft plan."

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            type:
              :attach_repo
              | :detach_repo
              | :create_link
              | :remove_link
              | :rewrite_file
              | :validate_repo
              | :run_command,
            target: String.t(),
            params: map(),
            depends_on: [non_neg_integer()],
            status: :pending | :running | :completed | :failed,
            result: any()
          }

    defstruct index: 0,
              type: nil,
              target: nil,
              params: %{},
              depends_on: [],
              status: :pending,
              result: nil
  end

  defmodule Precondition do
    @moduledoc "An assertion that must hold before plan execution."

    @type t :: %__MODULE__{
            type: :repo_exists | :repo_clean | :file_unchanged | :lock_available,
            target: String.t(),
            expected: any(),
            message: String.t()
          }

    defstruct [:type, :target, :expected, :message]
  end

  @type t :: %__MODULE__{
          id: String.t(),
          action: :attach | :detach | :repair | :migrate,
          status:
            :draft | :planned | :verified | :executing | :committed | :rolled_back | :failed,
          current: Workspace.t() | nil,
          desired: Workspace.t() | nil,
          preconditions: [Precondition.t()],
          operations: [Operation.t()],
          rollback: [Operation.t()],
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: Error.t() | nil
        }

  defstruct [
    :id,
    :action,
    :status,
    :current,
    :desired,
    preconditions: [],
    operations: [],
    rollback: [],
    created_at: nil,
    started_at: nil,
    completed_at: nil,
    error: nil
  ]

  @doc """
  Build a plan from a workspace diff.

  Given `current` and `desired` snapshots, compute the operations needed
  to transition between them.
  """
  @spec from_diff(Workspace.t(), Workspace.t()) :: t()
  def from_diff(%Workspace{} = current, %Workspace{} = desired) do
    delta = Diff.diff(current, desired)

    operations = delta_to_operations(delta)
    preconditions = derive_preconditions(current, operations)
    rollback = derive_rollback(operations)

    %__MODULE__{
      id: generate_id(),
      action: infer_action(delta),
      status: :planned,
      current: current,
      desired: desired,
      preconditions: preconditions,
      operations: with_indices(operations),
      rollback: with_indices(rollback),
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a plan for a `link.on` operation.

  Convenience: given a current snapshot and target app(s), compute the
  desired snapshot (with path links established) and build the plan.
  """
  @spec link_on(Workspace.t(), [atom()]) :: {:ok, t()} | {:error, Error.t()}
  def link_on(%Workspace{} = current, target_apps) when is_list(target_apps) do
    # Delegates to existing Link.Plan logic, wrapped in new shape
    case Graft.Link.Plan.build(current, target_apps, operation: :link_on) do
      {:ok, link_plan} ->
        desired = apply_link_plan_to_snapshot(current, link_plan)
        plan = from_diff(current, desired)
        {:ok, %{plan | action: :attach}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Verify that all preconditions hold against the current filesystem state.
  """
  @spec verify(t()) :: {:ok, t()} | {:error, t()}
  def verify(%__MODULE__{preconditions: preconditions, current: current} = plan) do
    repo_paths =
      if current do
        Map.new(current.repos, &{Atom.to_string(&1.name), &1.absolute_path})
      else
        %{}
      end

    failed =
      Enum.filter(preconditions, fn pc ->
        not precondition_holds?(repo_paths, pc)
      end)

    if failed == [] do
      {:ok, %{plan | status: :verified}}
    else
      messages = Enum.map(failed, & &1.message)

      error =
        Error.new(
          :plan_precondition_failed,
          "Precondition check failed: #{Enum.join(messages, "; ")}",
          %{failed_preconditions: failed}
        )

      {:error, %{plan | status: :failed, error: error}}
    end
  end

  @doc """
  True if the plan contains no operations.
  """
  @spec noop?(t()) :: boolean()
  def noop?(%__MODULE__{operations: []}), do: true
  def noop?(_), do: false

  ## ─── Diff → Operations ────────────────────────────────────────────

  defp delta_to_operations(%Diff.Delta{} = delta) do
    adds = Enum.map(delta.added, &entry_to_operation(&1, :add))
    rems = Enum.map(delta.removed, &entry_to_operation(&1, :remove))
    chgs = Enum.map(delta.changed, &entry_to_operation(&1, :change))

    adds ++ chgs ++ rems
  end

  defp entry_to_operation(%{path: [:repos, name], before: nil, after: _}, :add) do
    %Operation{type: :attach_repo, target: Atom.to_string(name)}
  end

  defp entry_to_operation(%{path: [:repos, name], before: _, after: nil}, :remove) do
    %Operation{type: :detach_repo, target: Atom.to_string(name)}
  end

  defp entry_to_operation(%{path: [:links, {repo, dep}], before: nil, after: _}, :add) do
    %Operation{type: :create_link, target: "#{repo}/#{dep}"}
  end

  defp entry_to_operation(%{path: [:links, {repo, dep}], before: _, after: nil}, :remove) do
    %Operation{type: :remove_link, target: "#{repo}/#{dep}"}
  end

  defp entry_to_operation(
         %{path: [:deps, {repo, _app}], before: before, after: after_val},
         :change
       ) do
    %Operation{
      type: :rewrite_file,
      target: Atom.to_string(repo),
      params: %{file: "mix.exs", before: before, after: after_val}
    }
  end

  defp entry_to_operation(%{path: path, before: before, after: after_val}, :change) do
    %Operation{
      type: :rewrite_file,
      target: path_to_string(path),
      params: %{before: before, after: after_val}
    }
  end

  defp entry_to_operation(entry, kind) do
    %Operation{
      type: :run_command,
      target: path_to_string(entry.path),
      params: %{kind: kind, before: entry.before, after: entry.after}
    }
  end

  ## ─── Preconditions ────────────────────────────────────────────────

  defp derive_preconditions(_current, operations) do
    repo_ops =
      Enum.filter(
        operations,
        &(&1.type in [:attach_repo, :detach_repo, :create_link, :remove_link])
      )

    affected_repos =
      repo_ops
      |> Enum.flat_map(&operation_repo_targets/1)
      |> Enum.uniq()

    Enum.map(affected_repos, fn repo ->
      %Precondition{
        type: :repo_exists,
        target: repo,
        expected: true,
        message: "Repo #{repo} must exist in workspace"
      }
    end)
  end

  defp operation_repo_targets(%Operation{type: :attach_repo, target: t}), do: [t]
  defp operation_repo_targets(%Operation{type: :detach_repo, target: t}), do: [t]

  defp operation_repo_targets(%Operation{type: :create_link, target: t}),
    do: String.split(t, "/", parts: 2)

  defp operation_repo_targets(%Operation{type: :remove_link, target: t}),
    do: String.split(t, "/", parts: 2)

  defp operation_repo_targets(_), do: []

  defp precondition_holds?(repo_paths, %Precondition{type: :repo_exists, target: repo}) do
    path = Map.get(repo_paths, repo, repo)
    File.dir?(path)
  end

  defp precondition_holds?(_repo_paths, _other), do: true

  ## ─── Rollback ───────────────────────────────────────────────────────

  defp derive_rollback(operations) do
    operations
    |> Enum.reverse()
    |> Enum.map(&invert_operation/1)
  end

  defp invert_operation(%Operation{type: :attach_repo, target: t}) do
    %Operation{type: :detach_repo, target: t}
  end

  defp invert_operation(%Operation{type: :detach_repo, target: t}) do
    %Operation{type: :attach_repo, target: t}
  end

  defp invert_operation(%Operation{type: :create_link, target: t}) do
    %Operation{type: :remove_link, target: t}
  end

  defp invert_operation(%Operation{type: :remove_link, target: t}) do
    %Operation{type: :create_link, target: t}
  end

  defp invert_operation(%Operation{type: :rewrite_file, target: t, params: p}) do
    %Operation{type: :rewrite_file, target: t, params: %{p | before: p.after, after: p.before}}
  end

  defp invert_operation(op), do: op

  ## ─── Helpers ────────────────────────────────────────────────────────

  defp infer_action(%Diff.Delta{added: [], removed: [_ | _]}), do: :detach
  defp infer_action(%Diff.Delta{added: [_ | _], removed: []}), do: :attach
  defp infer_action(%Diff.Delta{changed: [_ | _]}), do: :repair
  defp infer_action(_), do: :migrate

  defp with_indices(operations) do
    Enum.with_index(operations, fn op, idx -> %{op | index: idx} end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp path_to_string(path) when is_list(path) do
    path
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end

  ## ─── Link plan application ────────────────────────────────────────

  defp apply_link_plan_to_snapshot(%Workspace{} = snapshot, link_plan) do
    # Build a new snapshot with the links that would exist after link.on
    new_links =
      link_plan.changes
      |> Enum.filter(& &1.changed?)
      |> Enum.map(fn change ->
        %Workspace.Link{
          repo: change.repo,
          dep: change.target_app,
          mix_exs_sha256_before: change.mix_exs_before_hash,
          mix_exs_sha256_after: change.proposed_mix_exs_after_hash,
          preimage: change.dependency_source_before,
          replacement: change.dependency_source_after
        }
      end)

    # Merge with existing links (replacing matching entries)
    existing = Map.new(snapshot.links, &{{&1.repo, &1.dep}, &1})
    incoming = Map.new(new_links, &{{&1.repo, &1.dep}, &1})
    merged = Map.merge(existing, incoming) |> Map.values()

    %{snapshot | links: merged}
  end
end
