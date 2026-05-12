defmodule Graft.List do
  @moduledoc """
  Render the workspace manifest as a concise, read-only listing.

  Unlike `Graft.Status`, this does **not** snapshot the workspace, parse
  `mix.exs`, call `git`, or check Hex. It only reads `graft.exs` and
  checks whether each declared sibling path is present, missing, or
  obviously invalid on disk.

  ## Output formats

    * `:text` — human-readable table
    * `:json` — structured data for piping

  """

  alias Graft.{Error, Manifest}
  alias Graft.Manifest.Sibling

  @type format :: :text | :json

  @doc """
  Load the manifest from `dir` and render it.

  Returns `{:ok, String.t()}` on success or `{:error, Error.t()}` if the
  manifest cannot be read or validated.
  """
  @spec render(Path.t(), format()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(dir \\ File.cwd!(), format \\ :text) when format in [:text, :json] do
    with {:ok, manifest} <- Manifest.load(dir) do
      siblings = annotate_siblings(manifest.siblings)

      output =
        case format do
          :text -> render_text(manifest.root, siblings)
          :json -> render_json(manifest.root, siblings)
        end

      {:ok, output}
    end
  end

  ## ─── Data gathering ─────────────────────────────────────────────────

  defp annotate_siblings(siblings) do
    Enum.map(siblings, fn %Sibling{name: name, path: path, absolute_path: abs, origin: origin} ->
      status = sibling_status(abs)

      %{
        name: name,
        path: path,
        absolute_path: abs,
        origin: origin,
        exists: File.exists?(abs),
        status: status.status,
        detail: status.detail
      }
    end)
  end

  defp sibling_status(abs) do
    cond do
      not File.exists?(abs) ->
        %{status: :missing, detail: "path does not exist"}

      not File.dir?(abs) ->
        %{status: :invalid, detail: "path is not a directory"}

      not File.regular?(Path.join(abs, "mix.exs")) ->
        %{status: :invalid, detail: "missing mix.exs"}

      true ->
        %{status: :present, detail: "ready"}
    end
  end

  ## ─── Text rendering ─────────────────────────────────────────────────

  defp render_text(root, siblings) do
    count = length(siblings)

    header = [
      "Graft workspace: #{root}",
      "Siblings (#{count}):",
      ""
    ]

    lines =
      Enum.map(siblings, fn s ->
        status = "[#{s.status}]"
        detail = if s.status == :present, do: "", else: " #{s.detail}"
        "  #{pad_name(s.name)} #{pad_path(s.path)} #{status}#{detail}"
      end)

    (header ++ lines)
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp pad_name(name) do
    name
    |> to_string()
    |> String.pad_trailing(12)
  end

  defp pad_path(path) do
    path
    |> to_string()
    |> String.pad_trailing(16)
  end

  ## ─── JSON rendering ─────────────────────────────────────────────────

  defp render_json(root, siblings) do
    %{
      root: root,
      sibling_count: length(siblings),
      siblings:
        Enum.map(siblings, fn s ->
          %{
            name: to_string(s.name),
            path: s.path,
            absolute_path: s.absolute_path,
            origin: s.origin,
            exists: s.exists,
            status: Atom.to_string(s.status),
            detail: s.detail
          }
        end)
    }
    |> Jason.encode!()
  end
end
