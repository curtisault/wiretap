defmodule Wiretap.MixProject do
  use Mix.Project

  def project do
    [
      app: :wiretap,
      version: "0.1.0",
      elixir: "~> 1.17",
      description: "See who's listening on your Phoenix.PubSub topics — live.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/curtisault/wiretap"}
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:ex_unit]
      ],
      docs: [main: "Wiretap", extras: ["CHANGELOG.md"]]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Wiretap.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core runtime deps — the headless core must need nothing else.
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"},

      # Quality tooling (dev/test only).
      {:styler, "~> 1.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:doctor, "~> 0.21", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false}
    ]
  end
end
