defmodule Phlox.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/Xs-and-10s/phlox"

  def project do
    [
      app: :phlox,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex metadata
      description:
        "Graph-based orchestration engine for AI agent pipelines in Elixir. " <>
          "Three-phase node lifecycle (prep → exec → post), composable middleware, " <>
          "checkpointing with resume/rewind, batch flows, OTP supervision, " <>
          "and adapters for Phoenix LiveView and Datastar SSE.",
      package: package(),

      # Docs
      name: "Phlox",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Phlox.Application, []}
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "phlox",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "PocketFlow (original)" => "https://github.com/The-Pocket/PocketFlow"
      },
      maintainers: ["Mark Manley"],
      files:
        ~w(lib priv/static/phlox-spinner.css priv/static/favicon.ico .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Core: [Phlox, Phlox.Node, Phlox.BatchNode, Phlox.Flow, Phlox.BatchFlow, Phlox.Graph],
        Orchestration: [Phlox.Runner, Phlox.Pipeline, Phlox.Retry],
        Middleware: [Phlox.Middleware, Phlox.Middleware.Checkpoint],
        Checkpoint: [Phlox.Checkpoint, Phlox.Checkpoint.Memory, Phlox.Checkpoint.Ecto],
        OTP: [Phlox.FlowServer, Phlox.FlowSupervisor],
        Adapters: [Phlox.Adapter.Phoenix, Phlox.Adapter.Datastar],
        UI: [Phlox.Component],
        Observability: [Phlox.Telemetry]
      ]
    ]
  end
end
