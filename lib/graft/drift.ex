defmodule Graft.Drift do
  @moduledoc """
  Classification of observed-vs-desired state divergence.

  Drift tells us whether a managed resource:

    * `:none`      — matches desired state exactly
    * `:missing`   — expected to exist but absent
    * `:unexpected` — present but not expected
    * `:changed`   — present but differs from desired (e.g. wrong content, wrong path)

  Drift is computed after materialization to confirm the plan achieved its
  intended state, and before teardown to know what needs removing.
  """

  @type classification :: :none | :missing | :unexpected | :changed

  @type t :: %__MODULE__{
          repo: atom(),
          classification: classification(),
          desired_path: Path.t() | nil,
          observed_path: Path.t() | nil,
          details: map()
        }

  defstruct [:repo, :classification, :desired_path, :observed_path, details: %{}]

  @doc """
  Compare a desired repo entry against what is actually on disk.

  Returns a drift struct. For `:managed` repos we check the symlink/copy
  target; for `:external` repos we verify the source still exists.
  """
  @spec check(Graft.Workspace.Repo.t(), Path.t()) :: t()
  def check(%Graft.Workspace.Repo{} = repo, graft_root) do
    desired = Path.join(graft_root, Atom.to_string(repo.name))

    cond do
      repo.ownership == :managed and not File.exists?(desired) ->
        %__MODULE__{
          repo: repo.name,
          classification: :missing,
          desired_path: desired,
          observed_path: nil,
          details: %{reason: "managed entry not present in graft root"}
        }

      repo.ownership == :managed and File.exists?(desired) ->
        target = File.read_link(desired)

        case target do
          {:ok, link_target} when link_target == repo.absolute_path ->
            %__MODULE__{
              repo: repo.name,
              classification: :none,
              desired_path: desired,
              observed_path: desired,
              details: %{kind: :symlink, target: link_target}
            }

          {:ok, link_target} ->
            %__MODULE__{
              repo: repo.name,
              classification: :changed,
              desired_path: desired,
              observed_path: desired,
              details: %{
                kind: :symlink,
                expected_target: repo.absolute_path,
                observed_target: link_target
              }
            }

          {:error, :einval} ->
            # Not a symlink — could be a real directory or file
            %__MODULE__{
              repo: repo.name,
              classification: :changed,
              desired_path: desired,
              observed_path: desired,
              details: %{kind: :not_a_symlink}
            }

          {:error, reason} ->
            %__MODULE__{
              repo: repo.name,
              classification: :changed,
              desired_path: desired,
              observed_path: desired,
              details: %{kind: :read_error, reason: reason}
            }
        end

      repo.ownership == :external and not File.exists?(repo.absolute_path) ->
        %__MODULE__{
          repo: repo.name,
          classification: :missing,
          desired_path: repo.absolute_path,
          observed_path: nil,
          details: %{reason: "external source repo no longer exists"}
        }

      repo.ownership == :external and File.exists?(repo.absolute_path) ->
        %__MODULE__{
          repo: repo.name,
          classification: :none,
          desired_path: repo.absolute_path,
          observed_path: repo.absolute_path,
          details: %{kind: :external_source}
        }

      true ->
        %__MODULE__{
          repo: repo.name,
          classification: :none,
          desired_path: desired,
          observed_path: desired,
          details: %{}
        }
    end
  end

  @doc """
  True if the drift classification is `:none`.
  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{classification: :none}), do: true
  def ok?(_), do: false

  @doc """
  True if the drift classification is anything other than `:none`.
  """
  @spec drifted?(t()) :: boolean()
  def drifted?(drift), do: not ok?(drift)

  @doc """
  Human-readable one-line summary.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{repo: repo, classification: :none}),
    do: "#{repo}: no drift"

  def summary(%__MODULE__{repo: repo, classification: :missing, desired_path: path}),
    do: "#{repo}: missing (expected at #{path})"

  def summary(%__MODULE__{repo: repo, classification: :unexpected, observed_path: path}),
    do: "#{repo}: unexpected (found at #{path})"

  def summary(%__MODULE__{repo: repo, classification: :changed} = d),
    do: "#{repo}: changed (#{inspect(d.details)})"
end
