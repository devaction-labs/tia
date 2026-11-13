defmodule Tia.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/devaction-labs/tia"

  def project do
    [
      app: :tia,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Test impact analysis for ExUnit: run only the test files a change can affect.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps, do: [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
  end
end
