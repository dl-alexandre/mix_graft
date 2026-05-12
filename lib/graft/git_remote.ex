defmodule Graft.GitRemote do
  @moduledoc false

  @doc """
  Normalize common Git remote URL spellings for equality checks.

  This is intentionally conservative: it handles the GitHub HTTPS and SSH
  forms Graft writes itself, trims a trailing `.git`, and leaves unknown
  hosts otherwise unchanged.
  """
  @spec normalize_url(String.t() | nil) :: String.t() | nil
  def normalize_url(nil), do: nil

  def normalize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.replace_prefix("git@github.com:", "https://github.com/")
    |> String.replace_prefix("ssh://git@github.com/", "https://github.com/")
    |> String.replace_suffix(".git", "")
    |> String.trim_trailing("/")
  end

  @spec same?(String.t() | nil, String.t() | nil) :: boolean()
  def same?(left, right) when is_binary(left) and is_binary(right) do
    normalize_url(left) == normalize_url(right)
  end

  def same?(_, _), do: false
end
