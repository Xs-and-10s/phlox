<p align="center">
  <img src="priv/static/phlox-mark.png" alt="Phlox logo" width="64" height="64" />
</p>

# Phlox

[![Hex.pm](https://img.shields.io/hexpm/v/phlox.svg)](https://hex.pm/packages/phlox)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phlox)
[![License](https://img.shields.io/hexpm/l/phlox.svg)](LICENSE)

Graph-based orchestration engine for AI agent pipelines in Elixir.

Phlox gives you a three-phase node lifecycle (**prep → exec → post**),
declarative graph wiring, composable middleware, node-declared interceptors,
persistent checkpointing with resume and rewind, batch flows, OTP
supervision, swappable LLM providers, token compression, real-time adapters
for Phoenix LiveView and Datastar SSE, and a branded spinner — all in a
library small enough to read in an afternoon.

Phlox is an Elixir adaptation of
[PocketFlow](https://github.com/The-Pocket/PocketFlow) by
[The Pocket](https://github.com/The-Pocket), redesigned around explicit data
threading, behaviours, and OTP.

---

## Why Phlox?

Most LLM orchestration frameworks make three mistakes:

1. **Too much magic.** Implicit state, hidden retries, framework-owned HTTP clients.
2. **Not enough OTP.** No supervision, no fault tolerance, no introspection.
3. **Hard to test.** Nodes are tangled with the graph; you can't test them in isolation.

Phlox fixes all three. A node is just a module. The graph is just a map. State
is just a map passed by value. Every node is independently testable. Every flow
is supervisable.

|  | LangChain | CrewAI | Phlox |
|---|---|---|---|
| Core abstraction | Chain/Agent | Crew/Task | Graph of nodes |
| Elixir-native | ✗ | ✗ | ✓ |
| OTP supervision | ✗ | ✗ | ✓ |
| Step-through debugging | ✗ | ✗ | ✓ |
| Mutable shared state | ✓ | ✓ | ✗ (explicit threading) |
| Node isolation | ✗ | ✗ | ✓ |
| Zero required runtime deps | ✗ | ✗ | ✓ |

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
  - [The Three-Phase Lifecycle](#the-three-phase-lifecycle)
  - [Shared State](#shared-state)
  - [Graph Wiring](#graph-wiring)
  - [Routing and Branching](#routing-and-branching)
  - [Retry](#retry)
  - [Batch Flows](#batch-flows)
- [Orchestration](#orchestration)
  - [Runner (Zero-Dep Baseline)](#runner)
  - [Pipeline (Middleware-Aware)](#pipeline)
- [Middleware](#middleware)
- [Interceptors](#interceptors)
  - [Middleware vs. Interceptors](#middleware-vs-interceptors)
- [Checkpointing, Resume, and Rewind](#checkpointing-resume-and-rewind)
- [OTP Integration](#otp-integration)
  - [FlowServer](#flowserver)
  - [FlowSupervisor](#flowsupervisor)
  - [Monitor](#monitor)
- [LLM Adapters](#llm-adapters)
- [Token Compression: Simplect & Complect](#token-compression-simplect--complect)
- [Adapters](#adapters)
  - [Phoenix LiveView](#phoenix-liveview)
  - [Datastar SSE](#datastar-sse)
- [The Phlox Spinner](#the-phlox-spinner)
- [Telemetry](#telemetry)
- [Module Map](#module-map)
- [Design Philosophy](#design-philosophy)
- [Attribution](#attribution)

---

## Installation

Add `phlox` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phlox, "~> 0.5"}
  ]
end
```

Then run `mix deps.get`.

### Optional dependencies

Phlox's core has zero required dependencies beyond `:telemetry`. Everything
else is opt-in — declare only the deps you actually use:

| Feature | Dependency | When needed |
|---|---|---|
| LLM adapters | `{:req, "~> 0.5", optional: true}` | `Phlox.LLM.Groq`, `.Anthropic`, `.Google`, `.OpenAI`, `.Ollama` |
| Persistent checkpoints | `{:ecto_sql, "~> 3.10", optional: true}` | `Phlox.Checkpoint.Ecto` |
| Phoenix spinner component | `{:phoenix_live_view, "~> 1.0", optional: true}` | `Phlox.Component`, `Phlox.Adapter.Phoenix` |
| Datastar SSE adapter | `{:datastar_ex, "~> 0.1", optional: true}` | `Phlox.Adapter.Datastar` |
| Datastar Plug endpoint | `{:plug, "~> 1.14", optional: true}` | `Phlox.Adapter.Datastar.Plug` |
| Typed shared state | `{:gladius, ">= 0.0.0", optional: true}` | `Phlox.Typed` |

All optional deps use `Code.ensure_loaded?` guards. If you have the dep in
your project, the corresponding Phlox module compiles. If you don't, it's
silently skipped — no runtime errors, no unused code.

---

## Quick Start

### Step 1 — Define your nodes

Every node is a module implementing the `Phlox.Node` behaviour:

```elixir
defmodule MyApp.FetchNode do
  use Phlox.Node

  def prep(shared, _params) do
    Map.fetch!(shared, :url)
  end

  def exec(url, _params) do
    case Req.get!(url) do
      %{status: 200, body: body} -> {:ok, body}
      %{status: code}            -> {:error, "HTTP #{code}"}
    end
  end

  def post(shared, _prep_res, {:ok, body}, _params) do
    {:default, Map.put(shared, :body, body)}
  end

  def post(shared, _prep_res, {:error, reason}, _params) do
    {"error", Map.put(shared, :error, reason)}
  end
end

defmodule MyApp.CountWordsNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :body)

  def exec(body, _params) do
    body |> String.split() |> length()
  end

  def post(shared, _body, count, _params) do
    {:default, Map.put(shared, :word_count, count)}
  end
end
```

### Step 2 — Wire them into a graph

```elixir
alias Phlox.Graph

flow =
  Graph.new()
  |> Graph.add_node(:fetch, MyApp.FetchNode)
  |> Graph.add_node(:count, MyApp.CountWordsNode)
  |> Graph.add_node(:error, MyApp.ErrorNode)
  |> Graph.connect(:fetch, :count)                      # default action
  |> Graph.connect(:fetch, :error, action: "error")     # error branch
  |> Graph.start_at(:fetch)
  |> Graph.to_flow!()
```

### Step 3 — Run it

```elixir
result = Phlox.Runner.run(flow, %{url: "https://example.com"})
# => %{url: "...", body: "...", word_count: 1256}
```

That's it. No framework, no config files, no DSL to learn. Nodes are modules,
the graph is a map, state is a map.

---

## Core Concepts

### The Three-Phase Lifecycle

Every node runs three phases in sequence:

```
prep(shared, params)  →  exec(prep_res, params)  →  post(shared, prep_res, exec_res, params)
         │                        │                              │
    Read from shared         Do the work                  Write to shared
    Return prep_res          (HTTP, LLM, DB)              Return {action, new_shared}
                             No access to shared
                             This is the only phase
                             that retries
```

**Why this separation matters:**

`prep` reads. `exec` does. `post` writes and routes. This means:

- **`exec` is independently testable.** It receives only `prep_res` and
  `params` — no shared state, no graph context. You can call it directly
  in a test:

  ```elixir
  test "translates english to french" do
    result = MyApp.TranslateNode.exec(%{text: "hello", lang: "fr"}, %{})
    assert result == "bonjour"
  end
  ```

- **`exec` is the only phase that retries.** If `prep` or `post` fail,
  that's a bug in your code, not a flaky network. Phlox only retries
  I/O — the phase where transient failures actually happen.

- **`post` is a router.** The action string it returns determines the next
  node. Pattern match on `exec_res` to branch:

  ```elixir
  def post(shared, _prep, {:ok, data}, _params),    do: {:default, Map.put(shared, :data, data)}
  def post(shared, _prep, {:error, _}, _params),    do: {"retry_later", shared}
  def post(shared, _prep, :rate_limited, _params),  do: {"backoff", shared}
  ```

#### `exec_fallback/3` — Graceful degradation

When `exec/2` raises and all retries are exhausted, `exec_fallback/3` is
called. The default re-raises. Override it to degrade gracefully:

```elixir
def exec_fallback(_prep_res, _exception, _params) do
  {:ok, "[translation unavailable]"}
end
```

### Shared State

`shared` is a plain `%{}` map. It flows through every node by value — no
mutation, no hidden state, no process dictionary tricks, no magic assigns.

```
shared = %{url: "..."}
       │
  FetchNode.prep reads :url
  FetchNode.post writes :body
       │
  shared = %{url: "...", body: "..."}
       │
  CountNode.prep reads :body
  CountNode.post writes :word_count
       │
  shared = %{url: "...", body: "...", word_count: 1256}
```

This explicit threading is a deliberate departure from PocketFlow's Python
original, which mutates a shared dict in place. The Elixir version is more
verbose but eliminates an entire class of bugs: you can always see what data
flows where.

### Graph Wiring

```elixir
alias Phlox.Graph

flow =
  Graph.new()
  |> Graph.add_node(:classify, ClassifyNode)
  |> Graph.add_node(:summarize, SummarizeNode)
  |> Graph.add_node(:translate, TranslateNode)
  |> Graph.connect(:classify, :summarize, action: "text")
  |> Graph.connect(:classify, :translate, action: "foreign")
  |> Graph.start_at(:classify)
  |> Graph.to_flow!()
```

`to_flow!/1` validates at compile time:

- Missing start node → raises
- Unknown successor references → raises
- Overwritten action edges → warns (same as PocketFlow)

#### Node options

```elixir
Graph.add_node(:llm_call, ThinkNode, %{model: "claude-sonnet-4-20250514"},
  max_retries: 3,
  wait_ms: 1_000
)
```

The second argument (`%{model: ...}`) is `params` — immutable configuration
passed to every callback. `max_retries` and `wait_ms` control retry behavior.

### Routing and Branching

Branches are just pattern-matched `post/4` clauses returning different action
strings:

```elixir
defmodule MyApp.RouterNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :input_type)
  def exec(input_type, _params), do: input_type

  def post(shared, _prep, :image, _params),    do: {"image_pipeline", shared}
  def post(shared, _prep, :text, _params),     do: {"text_pipeline", shared}
  def post(shared, _prep, :audio, _params),    do: {"audio_pipeline", shared}
  def post(shared, _prep, unknown, _params),   do: {"error", Map.put(shared, :error, "Unknown: #{unknown}")}
end
```

Wire the branches in the graph:

```elixir
Graph.connect(:router, :image_handler,  action: "image_pipeline")
Graph.connect(:router, :text_handler,   action: "text_pipeline")
Graph.connect(:router, :audio_handler,  action: "audio_pipeline")
Graph.connect(:router, :error_handler,  action: "error")
```

#### Loops

Loops are just edges that point backward:

```elixir
# Agent loop: think → act → observe → think → ...
Graph.connect(:think, :act)
Graph.connect(:act, :observe)
Graph.connect(:observe, :think, action: "continue")
Graph.connect(:observe, :finish, action: "done")
```

The observe node decides whether to continue or finish based on the agent's
assessment of its own output.

### Retry

Per-node retry with exponential backoff and jitter:

```elixir
Graph.add_node(:llm_call, MyLLMNode, %{},
  max_retries: 3,
  wait_ms: 1_000
)
```

- `max_retries: 1` means one attempt, no retry (the default).
- `max_retries: 3` means up to three attempts.
- `wait_ms` is the base delay; Phlox applies exponential backoff with jitter.

Only `exec/2` retries. When all retries are exhausted, `exec_fallback/3` is
called.

### Batch Flows

`Phlox.BatchNode` and `Phlox.BatchFlow` execute the node lifecycle in
parallel across batched inputs. Same three-phase contract, automatic
fan-out/fan-in:

```elixir
defmodule MyApp.EmbedBatchNode do
  use Phlox.BatchNode

  def prep(shared, _params), do: shared[:chunks]  # returns a list

  # exec is called once per chunk, in parallel
  def exec(chunk, params) do
    Phlox.LLM.chat!(params.llm, [
      %{role: "user", content: "Embed: #{chunk}"}
    ], params.llm_opts)
  end

  def post(shared, _prep, results, _params) do
    {:default, Map.put(shared, :embeddings, results)}
  end
end
```

---

## Orchestration

Phlox provides two orchestrators. Use the one that matches your needs:

### Runner

`Phlox.Runner` is the zero-dependency baseline. A pure recursive loop —
no middleware, no interceptors, no telemetry, no side effects:

```elixir
result = Phlox.Runner.run(flow, %{url: "https://..."})
```

**Use Runner when:** scripting, testing, or building something that doesn't
need hooks or observability.

### Pipeline

`Phlox.Pipeline` wraps the same loop with middleware and interceptor support:

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  run_id: "ingest-run-42",
  middlewares: [MyApp.Middleware.CostTracker, Phlox.Middleware.Checkpoint],
  metadata: %{checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}}
)
```

Pipeline also emits telemetry events, which is how `Phlox.Monitor` knows
what's happening.

**Use Pipeline when:** you need middleware, interceptors, or real-time
monitoring.

**Runner stays untouched.** This is a hard design invariant. Pipeline is
built *on top of* Runner's logic. If you need to debug whether a problem is
in your middleware or your node, drop down to Runner and the middleware layer
disappears.

---

## Middleware

Middleware wraps the **entire node lifecycle** (prep → exec → post). It sees
`shared` before and after the node runs, and can modify both `shared` and
the `action` returned by `post`.

Middlewares are applied in list order before a node, and in **reverse** order
after — the onion model (first in, last out):

```
CostTracker.before_node  →  sees shared
  Checkpoint.before_node →  sees shared
    [prep → exec → post]
  Checkpoint.after_node  →  sees shared + action, persists checkpoint
CostTracker.after_node   →  sees shared + action, updates cost ledger
```

### Writing a middleware

```elixir
defmodule MyApp.Middleware.Logger do
  @behaviour Phlox.Middleware

  @impl true
  def before_node(shared, ctx) do
    IO.puts("[#{ctx.run_id}] Starting :#{ctx.node_id}")
    {:cont, shared}
  end

  @impl true
  def after_node(shared, action, ctx) do
    IO.puts("[#{ctx.run_id}] :#{ctx.node_id} → #{inspect(action)}")
    {:cont, shared, action}
  end
end
```

### Halting

Any middleware can halt the flow with `{:halt, reason}`, raising
`Phlox.HaltedError` with the module name and phase for diagnostics.

### Built-in middleware

- **`Phlox.Middleware.Checkpoint`** — persists `shared` after every node
- **`Phlox.Middleware.Simplect`** — injects token-compression system prompts

---

## Interceptors

Interceptors wrap the **exec phase only** — the boundary between `prep` and
`post`. They are declared on individual nodes, not passed to the pipeline.

```
Middleware.before_node  →  sees shared
  prep/2                →  reads shared, returns prep_res
    Interceptor.before_exec  →  sees prep_res, can modify it
    exec/2                   →  does the work
    Interceptor.after_exec   →  sees exec_res, can modify it
  post/4                →  writes to shared, returns action
Middleware.after_node   →  sees shared + action
```

### Declaring interceptors on a node

```elixir
defmodule MyApp.Nodes.Classifier do
  use Phlox.Node
  intercept Phlox.Interceptor.Complect, level: :ultra

  def prep(shared, _p), do: [%{role: "system", content: shared.system_prompt},
                              %{role: "user", content: shared.text}]
  def exec(msgs, p), do: Phlox.LLM.Groq.chat(msgs, p)
  def post(shared, _, {:ok, label}, _), do: {:default, Map.put(shared, :label, label)}
end
```

### Middleware vs. Interceptors

This is the key architectural distinction in Phlox:

| | Middleware | Interceptors |
|---|---|---|
| **Wraps** | Entire lifecycle (prep → exec → post) | Just `exec/2` |
| **Declared** | On the pipeline call site | On the node module |
| **Who controls** | The pipeline operator | The node author |
| **Sees** | `shared` (the flowing state map) | `prep_res` and `exec_res` |
| **Ordering** | Onion model (first in, last out) | Per-node, opt-in |
| **Purpose** | Cross-cutting (logging, checkpointing) | Node-specific (compression, caching) |
| **Analogy** | Plug middleware | Decorator on a single function |

**The design principle:** middleware is infrastructure that the pipeline
operator installs. Interceptors are capabilities that individual nodes
request. The node says "I want compression" — the interceptor provides it.
The pipeline operator says "I want checkpointing" — the middleware provides
it.

---

## Checkpointing, Resume, and Rewind

`Phlox.Checkpoint` is a behaviour with two adapters:

- **`Phlox.Checkpoint.Memory`** — Agent-backed, for dev and testing
- **`Phlox.Checkpoint.Ecto`** — append-only event log in Postgres

### Setup (Ecto)

```bash
mix phlox.gen.migration
mix ecto.migrate
```

### Using checkpoints

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  run_id: "ingest-run-42",
  middlewares: [Phlox.Middleware.Checkpoint],
  metadata: %{checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}}
)
```

### Resume

```elixir
{:ok, checkpoint} = Phlox.Checkpoint.Ecto.load("ingest-run-42", repo: MyApp.Repo)
Phlox.resume(checkpoint, flow: my_flow, middlewares: [...])
```

### Rewind

Detect a hallucination at node `:summarize`, three nodes after `:embed`.
Rewind to before `:embed` ran:

```elixir
{:ok, checkpoint} = Phlox.Checkpoint.Ecto.load_at("ingest-run-42",
  node_id: :chunk, repo: MyApp.Repo)
Phlox.resume(checkpoint, flow: my_flow, middlewares: [...])
```

---

## OTP Integration

### FlowServer

GenServer wrapping flow execution with async start, step-through debugging,
state inspection, and cancellation:

```elixir
{:ok, pid} = Phlox.FlowServer.start_link(
  flow: my_flow, shared: %{url: "..."}, middlewares: [Phlox.Middleware.Checkpoint])

Phlox.FlowServer.run(pid)
Phlox.FlowServer.status(pid)  # => :running | {:done, result}
Phlox.FlowServer.step(pid)    # => {:ok, %{current_id: :parse, shared: %{...}}}
```

### FlowSupervisor

DynamicSupervisor for concurrent flows:

```elixir
{Phlox.FlowSupervisor, name: :my_flows, max_children: 50}

{:ok, pid} = Phlox.FlowSupervisor.start_flow(:my_flows, my_flow, shared,
  middlewares: [Phlox.Middleware.Checkpoint], run_id: "run-42")
```

### Monitor

GenServer + ETS tracking all running flows via telemetry. Started
automatically by `Phlox.Application`.

```elixir
:ok = Phlox.Monitor.subscribe("my-flow-id")
# Receives: {:phlox_monitor, :node_done, snapshot}

snapshot = Phlox.Monitor.get("my-flow-id")
# => %{status: :running, current_id: :embed, nodes: %{fetch: %{status: :done, duration_ms: 142}}}
```

Both adapters (Phoenix and Datastar) subscribe to the Monitor.

---

## LLM Adapters

`Phlox.LLM` behaviour with five provider adapters (all require `{:req, "~> 0.5"}`):

| Adapter | Provider | Free tier | Requires |
|---|---|---|---|
| `Phlox.LLM.OpenAI` | GPT-4o / GPT-4.1 | $5 credits | `OPENAI_API_KEY` |
| `Phlox.LLM.Anthropic` | Claude | $5 credits | `ANTHROPIC_API_KEY` |
| `Phlox.LLM.Google` | Gemini AI Studio | 1,500 req/day | `GOOGLE_AI_KEY` |
| `Phlox.LLM.Groq` | Llama/Mistral | 14,400 req/day | `GROQ_API_KEY` |
| `Phlox.LLM.Ollama` | Local models | Unlimited | Ollama installed |

`Phlox.LLM.OpenAI` accepts `:base_url` for Azure, OpenRouter, or any
compatible endpoint.

### Swapping providers

The LLM is a node parameter — swap without changing node code:

```elixir
# Dev: fast and free
Graph.add_node(:think, ThinkNode, %{llm: Phlox.LLM.Groq, llm_opts: [model: "llama-3.3-70b-versatile"]})

# Prod: highest quality
Graph.add_node(:think, ThinkNode, %{llm: Phlox.LLM.Anthropic, llm_opts: [model: "claude-sonnet-4-20250514"]})
```

---

## Token Compression: Simplect & Complect

Inspired by [caveman](https://github.com/JuliusBrussee/caveman). Named after
Rich Hickey's "complect" — stripping to the essence is *simplecting*.

### Pipeline-wide

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  middlewares: [Phlox.Middleware.Simplect, Phlox.Middleware.Checkpoint],
  metadata: %{simplect: :full})
```

### Per-node overrides

```elixir
defmodule MyApp.Nodes.UserReport do
  use Phlox.Node
  intercept Phlox.Interceptor.Complect, level: :off  # full prose for humans
  # ...
end
```

### Direct usage

```elixir
[%{role: "user", content: "Explain GenServer"}]
|> Phlox.Simplect.wrap(:ultra)
|> Phlox.LLM.Groq.chat(model: "llama-3.3-70b-versatile")
```

| Level | Style | Savings |
|---|---|---|
| `:lite` | Drop filler, keep grammar | ~40% |
| `:full` | Drop articles, fragments OK | ~65% |
| `:ultra` | Abbreviate, arrows, max compression | ~75% |

---

## Adapters

### Phoenix LiveView

```elixir
defmodule MyAppWeb.IngestLive do
  use MyAppWeb, :live_view
  use Phlox.Adapter.Phoenix

  def mount(%{"flow_id" => flow_id}, _session, socket) do
    {:ok, phlox_subscribe(socket, flow_id)}
  end

  def render(assigns) do
    ~H"""
    <Phlox.Component.spinner spinning={@phlox_status == :running} size="32px" />
    <div>Status: {@phlox_status}</div>
    <div>Current: {@phlox_current_node}</div>
    """
  end
end
```

Or use the drop-in `Phlox.Adapter.Phoenix.FlowMonitor` LiveComponent.

### Datastar SSE

```elixir
# router.ex
get "/phlox/stream/:flow_id", Phlox.Adapter.Datastar.Plug, []
```

```html
<span class="phlox-spinner"
      data-class:spinning="$phlox_status === 'running'">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>
<span data-text="$phlox_status"></span>
```

---

## The Phlox Spinner

Three concentric rings spinning at different speeds and directions, evoking
petals in motion. Collapse-and-bloom transition on stop. Idle state doubles
as a logo mark.

### Phoenix

```elixir
<link rel="stylesheet" href={~p"/deps/phlox/priv/static/phlox-spinner.css"}>
<Phlox.Component.spinner spinning={@flow_running} size="48px" />
```

### Plain HTML / Datastar

```html
<link rel="stylesheet" href="/path/to/phlox-spinner.css">
<span class="phlox-spinner spinning">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>
```

### Collapse-and-bloom (JS)

```javascript
const sp = document.querySelector('.phlox-spinner');
sp.classList.remove('spinning');
sp.classList.add('collapsing');
setTimeout(() => {
  sp.querySelectorAll('.phlox-ring').forEach((r, i) => {
    r.style.transform = `rotate(${[0, 30, 60][i]}deg)`;
  });
}, 320);
sp.addEventListener('animationend', () => sp.classList.remove('collapsing'), { once: true });
```

### Customization

```css
.phlox-spinner {
  --phlox-ring-outer: #6366f1;
  --phlox-ring-middle: #818cf8;
  --phlox-ring-inner: #a5b4fc;
  --phlox-ring-track: rgba(255, 255, 255, 0.1);
  --phlox-spinner-size: 32px;
}
```

---

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:phlox, :flow, :start]` | `system_time` | `flow`, `shared`, `flow_id`, `run_id` |
| `[:phlox, :node, :start]` | `system_time` | `node_id`, `node`, `shared` |
| `[:phlox, :node, :stop]` | `duration` | `node_id`, `action`, `shared` |
| `[:phlox, :flow, :stop]` | `duration` | `flow`, `shared`, `flow_id`, `run_id`, `status` |
| `[:phlox, :flow, :exception]` | `duration` | `flow`, `kind`, `reason`, `stacktrace` |

Set `shared[:phlox_flow_id]` to correlate telemetry, Monitor, and checkpoints.

---

## Module Map

```
Module                              Purpose
──────                              ───────
Phlox                               Top-level delegations
Phlox.Node                          Behaviour: prep/2, exec/2, post/4, exec_fallback/3
Phlox.BatchNode                     Parallel exec over a list
Phlox.Graph                         Builder: new/add_node/connect/start_at/to_flow!
Phlox.Flow                          %Flow{} struct
Phlox.BatchFlow                     Batch variant
Phlox.Runner                        Pure recursive orchestration, no deps
Phlox.Pipeline                      Middleware + interceptor orchestration
Phlox.Retry                         Exponential backoff with jitter
Phlox.Middleware                    Behaviour: before_node/2, after_node/3
Phlox.Middleware.Checkpoint         Persist shared after each node
Phlox.Middleware.Simplect           Token-compression prompt injection
Phlox.Interceptor                   Behaviour: before_exec/2, after_exec/2
Phlox.Interceptor.Complect         Per-node simplect override
Phlox.HaltedError                   Structured error for middleware halts
Phlox.Checkpoint                    Behaviour: save/load/load_at/delete/list
Phlox.Checkpoint.Memory             Agent-backed adapter
Phlox.Checkpoint.Ecto               Append-only Postgres event log
Phlox.FlowServer                    GenServer: async run, step-through, inspection
Phlox.FlowSupervisor                DynamicSupervisor for concurrent flows
Phlox.Monitor                       GenServer + ETS: real-time flow tracking
Phlox.Telemetry                     :telemetry emission (soft-dep)
Phlox.LLM                           Behaviour: chat/2, chat!/3
Phlox.LLM.Anthropic                 Claude adapter
Phlox.LLM.Google                    Gemini AI Studio adapter
Phlox.LLM.Groq                      Groq inference adapter
Phlox.LLM.Ollama                    Local model adapter
Phlox.LLM.OpenAI                    OpenAI / Azure / OpenRouter adapter
Phlox.Simplect                      Token-compression engine (lite/full/ultra)
Phlox.Typed                         Typed shared state via Gladius
Phlox.Adapter.Phoenix               LiveView mixin
Phlox.Adapter.Phoenix.FlowMonitor   Drop-in LiveComponent
Phlox.Adapter.Datastar              SSE streaming via datastar_ex
Phlox.Adapter.Datastar.Plug         Plug endpoint for SSE
Phlox.Component                     Phoenix function component: spinner/1
```

---

## Design Philosophy

Phlox sits at the seam between **orchestration** (how nodes execute) and
**agent development** (how agents plan and act). It doesn't try to be a
harness — it defines the surface area where harness concerns attach:

- **Middleware** is where cross-cutting infrastructure hooks in. The pipeline
  operator controls this.
- **Interceptors** are where node-specific capabilities plug in. The node
  author controls this.
- **The core** is pure graph traversal. It doesn't know about LLMs, HTTP,
  databases, or AI. It just walks nodes and threads state.

You can use Phlox for a static RAG pipeline (pure orchestration, no agent),
or for a multi-agent system where agents plan which graph to execute next.
Phlox provides the execution substrate; the intelligence lives in your nodes.

---

## Attribution

Phlox is a port of **[PocketFlow](https://github.com/The-Pocket/PocketFlow)**
by [The Pocket](https://github.com/The-Pocket), originally written in Python.
PocketFlow's three-phase node lifecycle, graph wiring model, and batch flow
pattern are the direct inspiration.

The Elixir design — explicit data threading, OTP supervision, behaviour-based
nodes, composable middleware, persistent checkpoints with rewind, typed shared
state via Gladius, node-declared interceptors, `FlowServer`, `FlowSupervisor`,
`Monitor`, real-time adapters, LLM provider abstraction, and telemetry — is
Phlox's own contribution.

The Simplect/Complect token compression system is inspired by
[caveman](https://github.com/JuliusBrussee/caveman) by Julius Brussee, and
named after Rich Hickey's concept of "complected."

---

## License

MIT
