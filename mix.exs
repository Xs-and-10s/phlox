defmodule Phlox.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/Xs-and-10s/phlox"

  def project do
    [
      app: :phlox,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      name: "Phlox",
      description: """
      A graph-based orchestration engine for Elixir — built for AI agent
      pipelines, general enough for anything. Composable middleware,
      persistent checkpoints with rewind, typed shared state, node-declared
      interceptors, and swappable LLM providers. Zero required runtime deps.
      """,
      package: package(),
      source_url: @source_url,

      # Docs
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Phlox.Application, []}
    ]
  end

  defp deps do
    [
      # Dev/test only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Optional — enables telemetry events + Phlox.Monitor
      {:telemetry, "~> 1.0", optional: true},

      # Optional — enables typed shared state with full spec algebra
      {:gladius, "~> 0.6", optional: true},

      # Optional — enables LLM provider adapters (Anthropic, Google, Groq, Ollama)
      {:req, "~> 0.5", optional: true},

      # Optional — enables Phlox.Checkpoint.Ecto adapter
      # {:ecto_sql, "~> 3.0", optional: true},

      # Optional — enables Phlox.Adapter.Phoenix
      # {:phoenix_live_view, "~> 1.0", optional: true},
    ]
  end

  defp package do
    [
      name: "phlox",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(
        lib
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "Phlox",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        "Core": [
          Phlox,
          Phlox.Node,
          Phlox.BatchNode,
          Phlox.FanOutNode,
          Phlox.BatchFlow,
          Phlox.DSL,
          Phlox.Graph,
          Phlox.Flow,
          Phlox.Runner,
          Phlox.Pipeline,
          Phlox.Retry
        ],
        "Middleware": [
          Phlox.Middleware,
          Phlox.Middleware.Validate,
          Phlox.Middleware.Checkpoint
        ],
        "Interceptors": [
          Phlox.Interceptor
        ],
        "Typed State": [
          Phlox.Typed
        ],
        "Checkpoints": [
          Phlox.Checkpoint,
          Phlox.Checkpoint.Memory,
          Phlox.Checkpoint.Ecto
        ],
        "Resume / Rewind": [
          Phlox.Resume,
          Phlox.HaltedError
        ],
        "OTP": [
          Phlox.FlowServer,
          Phlox.FlowSupervisor,
          Phlox.Monitor
        ],
        "Adapters": [
          Phlox.Adapter.Phoenix,
          Phlox.Adapter.Datastar
        ],
        "LLM Providers": [
          Phlox.LLM,
          Phlox.LLM.Anthropic,
          Phlox.LLM.Google,
          Phlox.LLM.Groq,
          Phlox.LLM.Ollama
        ],
        "Telemetry": [
          Phlox.Telemetry
        ],
        "Examples": [
          Phlox.Examples.CodeReview
        ]
      ]
    ]
  end

  defp aliases do
    [
      test: ["test --trace"]
    ]
  end
end
