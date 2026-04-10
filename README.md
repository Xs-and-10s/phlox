# 🌸 Phlox

[![Hex.pm](https://img.shields.io/hexpm/v/phlox.svg)](https://hex.pm/packages/phlox)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phlox)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**A graph-based orchestration engine for Elixir — built for AI agent pipelines, general enough for anything.**

> Phlox is an Elixir port of [PocketFlow](https://github.com/The-Pocket/PocketFlow) by The Pocket,
> redesigned around Elixir idioms: explicit data threading, `Behaviour`-based nodes,
> and a pure orchestration loop built from the ground up for OTP supervision.

---

```
Current LLM frameworks are bloated.
You only need one clean abstraction: a graph.
```

Phlox gives you that graph — plus OTP supervision, composable middleware,
persistent checkpoints with rewind, typed shared state, node-declared
interceptors, and swappable LLM providers — in a library that fits
comfortably in your head.

---

## Table of Contents

- [Why Phlox?](#why-phlox)
- [Installation](#installation)
- [Core Concept: The Graph](#core-concept-the-graph)
- [Your First Flow](#your-first-flow)
- [Node Lifecycle In Depth](#node-lifecycle-in-depth)
- [Routing and Branching](#routing-and-branching)
- [Retry Logic](#retry-logic)
- [Batch Processing](#batch-processing)
- [Fan-Out: Mid-Flow Sub-Flows](#fan-out-mid-flow-sub-flows)
- [The DSL](#the-dsl)
- [Middleware](#middleware)
- [Checkpoints and Resume](#checkpoints-and-resume)
- [Typed Shared State](#typed-shared-state)
- [Interceptors](#interceptors)
- [OTP: Supervised Flows](#otp-supervised-flows)
- [Real-Time Monitoring](#real-time-monitoring)
- [Adapters: Phoenix and Datastar](#adapters-phoenix-and-datastar)
- [LLM Providers](#llm-providers)
- [Telemetry](#telemetry)
- [Design Patterns](#design-patterns)
- [Testing Your Nodes](#testing-your-nodes)
- [API Reference](#api-reference)
- [Attribution](#attribution)

---

## Why Phlox?

Most LLM orchestration frameworks make three mistakes:

1. **Too much magic** — implicit state, hidden retries, framework-owned I/O clients
2. **Not enough OTP** — no supervision, no fault tolerance, no introspection
3. **Hard to test** — nodes are tangled with the graph; you can't test them in isolation

Phlox fixes all three. A node is just a module. The graph is just a map. State is just
a map passed by value. Every node is independently testable. Every flow runs under OTP supervision.

| | LangChain | CrewAI | Phlox |
|---|---|---|---|
| Core abstraction | Chain / Agent | Crew / Task | Graph of nodes |
| Elixir-native | ✗ | ✗ | ✓ |
| OTP supervision | ✗ | ✗ | ✓ |
| Composable middleware | ✗ | ✗ | ✓ |
| Persistent checkpoints | ✗ | ✗ | ✓ |
| Typed shared state | ✗ | ✗ | ✓ |
| Node-declared interceptors | ✗ | ✗ | ✓ |
| Step-through debugging | ✗ | ✗ | ✓ |
| Real-time monitoring | ✗ | ✗ | ✓ |
| Node isolation | ✗ | ✗ | ✓ |
| Zero required runtime deps | ✗ | ✗ | ✓ |

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:phlox, "~> 0.3"},

    # Optional — enables telemetry events + Monitor
    {:telemetry, "~> 1.0"},

    # Optional — enables typed shared state with full spec algebra
    {:gladius, "~> 0.6"},

    # Optional — enables LLM provider adapters
    {:req, "~> 0.5"},

    # Optional — enables Ecto checkpoint adapter
    {:ecto_sql, "~> 3.0"},
    {:postgrex, ">= 0.0.0"},

    # Optional — enables Phoenix adapter
    {:phoenix_live_view, "~> 1.0"},
  ]
end
```

Phlox has **zero required runtime dependencies**. Every integration — telemetry,
Gladius, Ecto, Phoenix, Datastar — activates automatically when its deps are
present. No configuration needed.

---

## Core Concept: The Graph

Everything in Phlox is a **directed graph of nodes**.

```
[FetchNode] ──default──▶ [ParseNode] ──default──▶ [StoreNode]
     │
     └──"error"──▶ [ErrorNode]
```

- **Nodes** are Elixir modules implementing `Phlox.Node`. They receive data, do
  work, and pass updated data forward.
- **Edges** are action strings returned by `post/4`. Phlox follows the matching
  edge to find the next node.
- **Shared state** is a plain `%{}` map threaded through every node by value —
  no mutation, no hidden state, no surprises.

---

## Your First Flow

```elixir
defmodule MyApp.FetchNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :url)

  def exec(url, _params) do
    case HTTPoison.get(url) do
      {:ok, %{status_code: 200, body: body}} -> {:ok, body}
      {:ok, %{status_code: code}}            -> {:error, "HTTP #{code}"}
      {:error, reason}                       -> {:error, inspect(reason)}
    end
  end

  def post(shared, _prep, {:ok, body}, _params) do
    {:default, Map.put(shared, :body, body)}
  end

  def post(shared, _prep, {:error, reason}, _params) do
    {"error", Map.put(shared, :error, reason)}
  end
end

defmodule MyApp.WordCountNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :body)
  def exec(body, _params), do: body |> String.split(~r/\s+/, trim: true) |> length()

  def post(shared, _prep, count, _params) do
    {:default, Map.put(shared, :word_count, count)}
  end
end

# Wire the graph
alias Phlox.Graph

flow =
  Graph.new()
  |> Graph.add_node(:fetch, MyApp.FetchNode, %{}, max_retries: 3)
  |> Graph.add_node(:count, MyApp.WordCountNode, %{})
  |> Graph.connect(:fetch, :count)
  |> Graph.start_at(:fetch)
  |> Graph.to_flow!()

# Run it
{:ok, result} = Phlox.run(flow, %{url: "https://example.com"})
IO.puts("Word count: #{result.word_count}")
```

---

## Node Lifecycle In Depth

Every node runs three phases:

```
shared ──▶ prep(shared, params)
                │
                ▼ prep_res
           exec(prep_res, params)   ◀── retry loop + interceptors wrap this
                │
                ▼ exec_res
           post(shared, prep_res, exec_res, params)
                │
                ▼ {action, new_shared}
```

**`prep/2`** — Reads from `shared`, returns data for `exec`. Pure, no side effects.

**`exec/2`** — Does the work: HTTP calls, LLM requests, DB queries. Has **no access
to `shared`** — only what `prep` handed it. This is what makes every node
independently testable.

**`post/4`** — Updates state and decides the next action. Returns `{action, new_shared}`.
Use `:default` for the normal forward path.

**`exec_fallback/3`** — Called when all retries are exhausted. Default re-raises.
Override to degrade gracefully.

---

## Routing and Branching

Branches are pattern-matched `post/4` clauses returning different action strings.

```elixir
defmodule MyApp.RouterNode do
  use Phlox.Node

  def prep(shared, _p), do: Map.fetch!(shared, :request_type)
  def exec(type, _p), do: type

  def post(shared, _p, :summarise, _p2), do: {"summarise", shared}
  def post(shared, _p, :translate, _p2), do: {"translate", shared}
  def post(shared, _p, _unknown,   _p2), do: {"error",     shared}
end
```

---

## Retry Logic

```elixir
Graph.add_node(:fetch, MyApp.FetchNode, %{}, max_retries: 3, wait_ms: 1000)
```

With `max_retries: 3, wait_ms: 1000`:

```
attempt 1 → raises → sleep 1000ms
attempt 2 → raises → sleep 1000ms
attempt 3 → raises → exec_fallback/3 called
```

---

## Batch Processing

**Sequential:** Implement `exec_one/2`. `prep/2` returns the list.

```elixir
defmodule MyApp.TranslateManyNode do
  use Phlox.BatchNode

  def prep(shared, _p), do: Map.fetch!(shared, :texts)
  def exec_one(text, params), do: MyLLM.translate(text, to: params.target_language)
  def post(shared, _prep, translations, _p), do: {:default, Map.put(shared, :translations, translations)}
end
```

**Parallel:** Add `parallel: true`. Results are always in input order.

```elixir
use Phlox.BatchNode, parallel: true, max_concurrency: 10, timeout: 15_000
```

---

## Middleware

Middleware wraps the entire node lifecycle — `before_node` fires before `prep`,
`after_node` fires after `post`. Middlewares compose in onion order.

```
before_node (mw1 → mw2 → mw3)
  │
  prep → exec → post            ← node work
  │
after_node  (mw3 → mw2 → mw1)
```

### Implementing a middleware

```elixir
defmodule MyApp.Middleware.CostTracker do
  @behaviour Phlox.Middleware

  @impl true
  def before_node(shared, _ctx) do
    {:cont, Map.put(shared, :_node_start, System.monotonic_time())}
  end

  @impl true
  def after_node(shared, action, _ctx) do
    elapsed = System.monotonic_time() - shared._node_start
    costs = Map.update(shared, :_costs, [elapsed], &[elapsed | &1])
    {:cont, Map.delete(costs, :_node_start), action}
  end
end
```

### Using middleware

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  middlewares: [
    Phlox.Middleware.Validate,     # typed state enforcement
    MyApp.Middleware.CostTracker,  # cost tracking
    Phlox.Middleware.Checkpoint    # persistent checkpoints
  ],
  run_id: "my-run-001",
  metadata: %{checkpoint: {Phlox.Checkpoint.Memory, []}}
)
```

### Halting

Return `{:halt, reason}` from any callback to abort the flow. The pipeline
raises `Phlox.HaltedError` with the reason, node id, middleware module, and
phase (`:before_node` or `:after_node`).

---

## Checkpoints and Resume

Checkpoint middleware persists `shared` after each node completes, creating
an append-only event log. Flows survive restarts, and you can rewind to any
node to re-execute from a known-good state.

### Enabling checkpoints

```elixir
# In-memory (development/testing)
{:ok, _} = Phlox.Checkpoint.Memory.start_link()

Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  middlewares: [Phlox.Middleware.Checkpoint],
  run_id: "ingest-001",
  metadata: %{
    checkpoint: {Phlox.Checkpoint.Memory, []},
    flow_name: "IngestPipeline"
  }
)

# Ecto/Postgres (production)
# 1. Add {:ecto_sql, "~> 3.0"} to deps
# 2. Run: mix phlox.gen.migration && mix ecto.migrate
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  middlewares: [Phlox.Middleware.Checkpoint],
  run_id: "ingest-001",
  metadata: %{
    checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo},
    flow_name: "IngestPipeline"
  }
)
```

### Resume after crash

```elixir
{:ok, result} = Phlox.Resume.resume("ingest-001",
  flow: my_flow,
  checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}
)
```

### Rewind to a specific node

Detected a hallucination at node `:embed`? Rewind to the checkpoint saved
after `:chunk` and re-execute everything downstream:

```elixir
{:ok, result} = Phlox.Resume.rewind("ingest-001", :chunk,
  flow: my_flow,
  checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}
)
```

### Checkpoint history

Every node completion is an immutable event with a monotonic sequence number:

```elixir
{:ok, history} = Phlox.Checkpoint.Memory.history("ingest-001")
# [
#   %{sequence: 1, node_id: :fetch, next_node_id: :parse, event_type: :node_completed, ...},
#   %{sequence: 2, node_id: :parse, next_node_id: :embed, event_type: :node_completed, ...},
#   %{sequence: 3, node_id: :embed, next_node_id: nil,    event_type: :flow_completed, ...}
# ]
```

---

## Typed Shared State

Declare what `shared` must look like entering and leaving each node.
Uses [Gladius](https://hex.pm/packages/gladius) for the full spec algebra,
or plain functions as a zero-dep fallback.

### With Gladius

```elixir
defmodule MyApp.EmbedNode do
  use Phlox.Node
  use Phlox.Typed

  import Gladius

  input open_schema(%{
    required(:text)     => string(:filled?),
    required(:language) => string(:filled?)
  })

  output open_schema(%{
    required(:text)      => string(:filled?),
    required(:language)  => string(:filled?),
    required(:embedding) => list_of(spec(is_list()))
  })

  def prep(shared, _p), do: {shared.text, shared.language}
  def exec({text, lang}, _p), do: MyLLM.embed(text, lang)
  def post(shared, _p, emb, _p2), do: {:default, Map.put(shared, :embedding, emb)}
end
```

Gladius specs are parse-don't-validate: `conform/2` returns a **shaped** value
with coercions, transforms, and defaults applied. The middleware replaces
`shared` with the shaped output, so specs actively participate in data flow.

### Without Gladius (plain functions)

```elixir
input fn shared ->
  if is_binary(shared[:text]), do: :ok, else: {:error, ":text required"}
end
```

### Enabling validation

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  middlewares: [Phlox.Middleware.Validate]
)
```

Nodes without specs are silently skipped — safe to include globally.

---

## Interceptors

Interceptors are the complement to middleware. Where middleware wraps the
entire node lifecycle and is configured at the **pipeline** level, interceptors
wrap **just `exec/2`** and are declared by the **node itself**.

```
Middleware = what the framework does to every node.
Interceptors = what nodes declare they want done to themselves.
```

### Declaring interceptors

```elixir
defmodule MyApp.EmbedNode do
  use Phlox.Node

  intercept MyApp.Interceptor.Cache, ttl: :timer.minutes(5)
  intercept MyApp.Interceptor.RateLimit, max: 10, per: :second

  def exec(text, _params), do: MyLLM.embed(text)
end
```

### How they execute

Interceptors run inside the retry loop, wrapping each attempt:

```
Retry loop:
  attempt 1 → before_exec → exec → after_exec → (raises)
  attempt 2 → before_exec → exec → after_exec → success
```

### Implementing an interceptor

```elixir
defmodule MyApp.Interceptor.Cache do
  @behaviour Phlox.Interceptor

  @impl true
  def before_exec(prep_res, ctx) do
    case lookup(prep_res, ctx.interceptor_opts[:ttl]) do
      {:hit, value} -> {:skip, value}   # short-circuit exec entirely
      :miss         -> {:cont, prep_res}
    end
  end

  @impl true
  def after_exec(exec_res, ctx) do
    store(ctx.prep_res, exec_res, ctx.interceptor_opts[:ttl])
    {:cont, exec_res}
  end
end
```

### Access boundary

Interceptors see `prep_res` and `exec_res` but **not** `shared`. They cannot
change routing. This is the fundamental distinction from middleware.

---

## OTP: Supervised Flows

### FlowServer

Wraps a flow in a GenServer with middleware and interceptor support:

```elixir
{:ok, pid} = Phlox.FlowServer.start_link(
  flow: my_flow,
  shared: %{url: "..."},
  middlewares: [Phlox.Middleware.Validate, Phlox.Middleware.Checkpoint],
  run_id: "job-001",
  metadata: %{checkpoint: {Phlox.Checkpoint.Memory, []}}
)

# Run to completion
{:ok, final} = Phlox.FlowServer.run(pid)

# Or step through with middleware hooks firing per step
{:continue, :parse, shared} = Phlox.FlowServer.step(pid)
{:done, final}              = Phlox.FlowServer.step(pid)

# Resume from checkpoint
{:ok, pid} = Phlox.FlowServer.start_link(
  flow: my_flow,
  resume: "job-001",
  checkpoint: {Phlox.Checkpoint.Memory, []}
)
```

### FlowSupervisor

Spawn named flows at runtime under a DynamicSupervisor:

```elixir
{:ok, _} = Phlox.FlowSupervisor.start_flow(:my_job, flow, shared)
{:ok, result} = Phlox.FlowServer.run(Phlox.FlowSupervisor.server(:my_job))

Phlox.FlowSupervisor.running()    # => [:my_job, ...]
Phlox.FlowSupervisor.stop_flow(:my_job)
```

---

## Real-Time Monitoring

`Phlox.Monitor` tracks every running flow in ETS via telemetry events.

```elixir
# Query
snapshot = Phlox.Monitor.get("my-flow-id")

# Subscribe
:ok = Phlox.Monitor.subscribe("my-flow-id")
receive do
  {:phlox_monitor, :node_done, snapshot} -> IO.inspect(snapshot)
end
```

---

## Adapters: Phoenix and Datastar

Both adapters read from `Phlox.Monitor`. A Phoenix app using Datastar for its
frontend can run both simultaneously.

### Phoenix LiveView

```elixir
defmodule MyAppWeb.JobLive do
  use MyAppWeb, :live_view
  use Phlox.Adapter.Phoenix

  def mount(%{"flow_id" => flow_id}, _session, socket) do
    {:ok, phlox_subscribe(socket, flow_id)}
  end
end
```

### Datastar SSE

```elixir
# In your router
get "/phlox/stream/:flow_id", Phlox.Adapter.Datastar.Plug, []
```

---

## LLM Providers

Phlox ships with a `Phlox.LLM` behaviour and adapters for major providers.
The provider is injected via node `params` — swapping is one line.

### Available adapters

| Adapter | Provider | Free tier | Requires |
|---|---|---|---|
| `Phlox.LLM.Google` | Gemini via AI Studio | 1,500 req/day | `GOOGLE_AI_KEY` |
| `Phlox.LLM.Groq` | Llama/Mistral on Groq | 14,400 req/day | `GROQ_API_KEY` |
| `Phlox.LLM.Anthropic` | Claude API | $5 free credits | `ANTHROPIC_API_KEY` |
| `Phlox.LLM.Ollama` | Local models | Unlimited | Ollama installed |

### Using in a node

```elixir
defmodule MyApp.ThinkNode do
  use Phlox.Node

  def prep(shared, _p), do: shared.prompt

  def exec(prompt, params) do
    provider = Map.fetch!(params, :llm)
    messages = [
      %{role: "system", content: "You are a helpful assistant."},
      %{role: "user", content: prompt}
    ]
    Phlox.LLM.chat!(provider, messages, params[:llm_opts] || [])
  end

  def post(shared, _p, response, _p2) do
    {:default, Map.put(shared, :response, response)}
  end
end
```

### Swapping providers

```elixir
# Development — free
Graph.add_node(:think, ThinkNode, %{llm: Phlox.LLM.Google, llm_opts: [model: "gemini-2.5-flash"]})

# Production — highest quality
Graph.add_node(:think, ThinkNode, %{llm: Phlox.LLM.Anthropic, llm_opts: [model: "claude-sonnet-4-6"]})
```

### Included example: Code Review Brain Trust

```elixir
{:ok, result} = Phlox.Examples.CodeReview.run(~S"""
  def fetch_user(id) do
    query = "SELECT * FROM users WHERE id = #{id}"
    Repo.query!(query)
  end
""",
  llm: Phlox.LLM.Groq,
  llm_opts: [model: "llama-3.3-70b-versatile"],
  language: "elixir"
)

IO.puts(result.final_review)
```

Three specialist agents (security, logic, style) analyze code from different
angles, then a synthesizer combines, deduplicates, and ranks findings.

---

## Telemetry

Phlox emits telemetry events when `:telemetry` is present. Zero overhead when absent.

| Event | Measurements | When |
|---|---|---|
| `[:phlox, :flow, :start]` | `system_time` | flow begins |
| `[:phlox, :flow, :stop]` | `duration` | flow finishes |
| `[:phlox, :node, :start]` | `system_time` | before `prep/2` |
| `[:phlox, :node, :stop]` | `duration` | after `post/4` |
| `[:phlox, :node, :exception]` | `duration` | node raises after all retries |

---

## Design Patterns

### Simple Pipeline

```elixir
defmodule MyApp.IngestFlow do
  use Phlox.DSL

  node :fetch, FetchNode, %{}, max_retries: 3
  node :clean, CleanNode, %{}
  node :embed, EmbedNode, %{model: "ada-002"}
  node :store, StoreNode, %{}

  connect :fetch, :clean
  connect :clean, :embed
  connect :embed, :store

  start_at :fetch
end
```

### Agent Loop (ReAct)

```elixir
connect :think, :act,    action: "continue"
connect :think, :finish, action: "done"
connect :act,   :think   # loop back
```

### Multi-Agent Brain Trust

Three specialists review from different angles, then a synthesizer combines.
See `Phlox.Examples.CodeReview` for a working implementation.

---

## Testing Your Nodes

Because `exec/2` has no access to `shared`, nodes are trivially testable in isolation:

```elixir
test "translates text to target language" do
  result = MyApp.TranslateNode.exec(%{text: "hello", language: "fr"}, %{})
  assert result == {:ok, "bonjour"}
end

test "routes to :default on success" do
  {action, new_shared} = MyApp.TranslateNode.post(%{}, nil, {:ok, "bonjour"}, %{})
  assert action == :default
  assert new_shared.translation == "bonjour"
end
```

---

## API Reference

### Module map

```
Phlox                          top-level: run/2
Phlox.Node                     behaviour + __using__ macro + intercept
Phlox.BatchNode                exec_one/2 per item
Phlox.FanOutNode               sub_flow per item
Phlox.BatchFlow                full-flow fan-out
Phlox.DSL                      declarative flow definition
Phlox.Graph                    builder: new/add_node/connect/start_at/to_flow[!]
Phlox.Flow                     %Flow{} struct + run/2 (delegates to Pipeline)
Phlox.Runner                   orchestrate/3 (pure, no middleware, no telemetry)
Phlox.Pipeline                 orchestrate/4 (middleware + interceptor + telemetry)
Phlox.Retry                    run/3 (exec with retry + optional interceptor wrapping)
Phlox.Middleware               behaviour: before_node/2, after_node/3
Phlox.Middleware.Validate      enforces Phlox.Typed specs at node boundaries
Phlox.Middleware.Checkpoint    persists shared after each node
Phlox.Interceptor              behaviour: before_exec/2, after_exec/2 + intercept macro
Phlox.Typed                    use macro: input/1, output/1 spec declarations
Phlox.Checkpoint               behaviour: save/load_latest/load_at/history/delete
Phlox.Checkpoint.Memory        in-memory adapter (Agent-backed)
Phlox.Checkpoint.Ecto          Postgres adapter (append-only event log)
Phlox.Resume                   resume/2, rewind/3
Phlox.HaltedError              raised when middleware/interceptor halts
Phlox.FlowServer               GenServer: run/step/state/reset + middleware + resume
Phlox.FlowSupervisor           DynamicSupervisor: start_flow/stop_flow/whereis
Phlox.Monitor                  GenServer+ETS: get/list/subscribe/unsubscribe
Phlox.Telemetry                soft-dep telemetry emission
Phlox.Adapter.Phoenix          LiveView mixin + FlowMonitor component
Phlox.Adapter.Datastar         SSE streaming via Plug
Phlox.LLM                      behaviour: chat/2
Phlox.LLM.Anthropic            Claude API adapter
Phlox.LLM.Google               Gemini AI Studio adapter
Phlox.LLM.Groq                 Groq inference adapter
Phlox.LLM.Ollama               Local model adapter
```

### Key invariants

1. **`exec/2` has NO access to `shared`** — only what `prep/2` returned.
2. **`post/4` must return `{action, new_shared}`** — always a tuple.
3. **Middleware wraps the node lifecycle** — sees `shared` and `action`.
4. **Interceptors wrap `exec/2`** — sees `prep_res` and `exec_res`, not `shared`.
5. **Runner stays pure** — Pipeline adds middleware, interceptors, and telemetry on top. `Flow.run/2` and `FlowServer` use Pipeline; call `Runner.orchestrate/3` directly when you need zero side effects (e.g. property-based tests).
6. **Checkpoint events are append-only** — immutable once written.
7. **`shared` key `:phlox_flow_id`** is reserved for telemetry. Auto-injected from `run_id` if not provided by the caller.

---

## Attribution

Phlox is a port of **[PocketFlow](https://github.com/The-Pocket/PocketFlow)**
by [The Pocket](https://github.com/The-Pocket), originally written in Python.
PocketFlow's three-phase node lifecycle (`prep → exec → post`), graph wiring
model, and batch flow pattern are the direct inspiration for this library.

The Elixir design — explicit data threading, OTP supervision, behaviour-based
nodes, composable middleware, persistent checkpoints with rewind, typed shared
state via [Gladius](https://hex.pm/packages/gladius), node-declared interceptors,
`FlowServer`, `FlowSupervisor`, `Monitor`, real-time adapters, LLM provider
abstraction, and telemetry — is Phlox's own contribution.

---

## License

MIT
