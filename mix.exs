defmodule PhoenixKitSync.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :phoenix_kit_sync,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitSync",
      source_url: "https://github.com/mdon/phoenix_kit_sync",
      description: "Peer-to-peer data sync module for PhoenixKit"
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:phoenix_kit, path: "../phoenix_kit"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:ecto_sql, "~> 3.10"},
      {:websockex, "~> 0.5.1"},
      {:websock_adapter, "~> 0.5"},
      {:oban, "~> 2.13"},
      {:jason, "~> 1.0"},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
