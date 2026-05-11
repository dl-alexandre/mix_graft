defmodule Graft.CLI.Errors do
  @moduledoc false

  # Shared error-formatting helpers for `Mix.Tasks.Graft.*` tasks.
  # In `:text` mode, returns a concise human message routed to stderr.
  # In `:json` mode, returns a structured JSON document on stdout.

  alias Graft.Error

  @type stream :: :stdout | :stderr

  @spec format(Error.t(), :text | :json, String.t()) :: {:error, String.t(), stream()}
  def format(%Error{} = err, :text, task_name) do
    {:error, "#{task_name}: #{err.message}", :stderr}
  end

  def format(%Error{} = err, :json, _task_name) do
    payload = %{
      error: %{
        kind: to_string(err.kind),
        message: err.message,
        details: jsonable(err.details)
      }
    }

    {:error, Jason.encode!(payload), :stdout}
  end

  @doc "Recursively coerce values to JSON-safe shapes (atoms → strings, etc.)."
  def jsonable(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  end

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

  def jsonable(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: to_string(atom)

  def jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  def jsonable(v), do: inspect(v)
end
