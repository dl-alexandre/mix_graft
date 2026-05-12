defmodule Graft.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/dl-alexandre/mix_graft"
  @description "Transactional workspace tooling for Elixir OSS contributors."

  def project do
    [
      app: :mix_graft,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: @description,
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files:
        ~w(lib docs scripts/graft_quickstart_smoke.sh mix.exs README.md LICENSE CHANGELOG.md usage-rules.md),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "usage-rules.md",
        "docs/trust_guarantees.md"
      ],
      source_ref: "v#{@version}"
    ]
  end
end
