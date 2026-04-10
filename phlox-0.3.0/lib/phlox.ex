# top-level convenience (run/2, graph/0)

defmodule Phlox do
  @moduledoc """
  A graph-based orchestration engine for Elixir — built for AI agent
  pipelines, general enough for anything.

  Phlox is an Elixir port of [PocketFlow](https://github.com/The-Pocket/PocketFlow),
  redesigned around Elixir idioms: explicit data threading, behaviour-based nodes,
  and a pure orchestration loop built for GenServer wrapping.

  ## What Phlox gives you

  - **Composable middleware** — wrap every node with checkpointing, validation,
    cost tracking, approval gates, or anything else. Onion-model execution.
  - **Persistent checkpoints with rewind** — append-only event log. Flows
    survive restarts. Rewind to any node to re-execute from a known-good state.
  - **Typed shared state** — declare what `shared` must look like at each node
    boundary. Uses [Gladius](https://hex.pm/packages/gladius) for the full spec
    algebra, or plain functions as a zero-dep fallback.
  - **Node-declared interceptors** — nodes declare their own exec-boundary
    hooks (caching, rate limiting, circuit breakers). Middleware is what the
    framework does to every node; interceptors are what nodes declare they want
    done to themselves.
  - **Swappable LLM providers** — adapters for Anthropic, Google AI Studio,
    Groq, and Ollama. Swap providers with one line; the flow graph doesn't change.
  - **OTP supervision** — every flow runs under a GenServer with step-through
    debugging, state inspection, and named supervision via DynamicSupervisor.
  - **Real-time monitoring** — ETS-backed flow tracking with subscriber
    notifications. Phoenix LiveView and Datastar SSE adapters included.
  - **Zero required runtime deps** — telemetry, Gladius, Ecto, Phoenix, Req
    all activate automatically when present. Phlox alone is pure Elixir + OTP.

  ## Quick start

      # 1. Define nodes
      defmodule FetchNode do
        use Phlox.Node

        def prep(shared, _params), do: Map.fetch!(shared, :url)
        def exec(url, _params), do: HTTPoison.get!(url).body
        def post(shared, _prep, body, _params), do: {:default, Map.put(shared, :body, body)}
      end

      # 2. Wire the graph
      flow =
        Phlox.graph()
        |> Phlox.Graph.add_node(:fetch, FetchNode, %{}, max_retries: 3)
        |> Phlox.Graph.add_node(:count, CountNode, %{})
        |> Phlox.Graph.connect(:fetch, :count)
        |> Phlox.Graph.start_at(:fetch)
        |> Phlox.Graph.to_flow!()

      # 3. Run it
      {:ok, result} = Phlox.run(flow, %{url: "https://example.com"})

      # 4. Or run with middleware (validation + checkpointing)
      {:ok, _} = Phlox.Checkpoint.Memory.start_link()

      result = Phlox.Pipeline.orchestrate(flow, flow.start_id, %{url: "..."},
        middlewares: [Phlox.Middleware.Validate, Phlox.Middleware.Checkpoint],
        run_id: "my-run-001",
        metadata: %{checkpoint: {Phlox.Checkpoint.Memory, []}}
      )

      # 5. Resume after a crash
      {:ok, result} = Phlox.Resume.resume("my-run-001",
        flow: flow,
        checkpoint: {Phlox.Checkpoint.Memory, []}
      )

  ## Architecture at a glance

      ┌─────────────────────────────────────────────────────────────┐
      │  Middleware (pipeline level)                                │
      │  before_node → ... → after_node                             │
      │                                                             │
      │    prep(shared, params) → prep_res                          │
      │                                                             │
      │      ┌─ Interceptors (node level, inside retry loop) -─┐    │
      │      │  before_exec → exec(prep_res, params) →         │    │
      │      │  after_exec                                     │    │
      │      └─────────────────────────────────────────────────┘    │
      │                                                             │
      │    post(shared, prep_res, exec_res, params)                 │
      │      → {action, new_shared}                                 │
      └─────────────────────────────────────────────────────────────┘

  ## Key modules

  | Module | Purpose |
  |---|---|
  | `Phlox.Node` | Behaviour for graph nodes (prep → exec → post) |
  | `Phlox.Graph` | Builder API for wiring nodes into flows |
  | `Phlox.Pipeline` | Orchestrator with middleware + interceptor support |
  | `Phlox.Middleware` | Behaviour for composable flow-level hooks |
  | `Phlox.Interceptor` | Behaviour for node-declared exec-boundary hooks |
  | `Phlox.Typed` | Input/output spec declarations on nodes |
  | `Phlox.Checkpoint` | Behaviour for persistent state adapters |
  | `Phlox.Resume` | Resume and rewind from checkpoints |
  | `Phlox.FlowServer` | GenServer wrapper with step-through debugging |
  | `Phlox.LLM` | Behaviour for swappable LLM providers |
  """

  alias Phlox.{Graph, Flow}

  @doc "Shortcut for `Phlox.Flow.run/2`."
  defdelegate run(flow, shared \\ %{}), to: Flow

  @doc "Shortcut for `Phlox.Graph.new/0`."
  defdelegate graph(), to: Graph, as: :new
end
