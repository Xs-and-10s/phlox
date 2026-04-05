# 🌸 Phlox

**A graph-based orchestration engine for Elixir — built for AI agent pipelines, general enough for anything.**

> Phlox is an Elixir port of [PocketFlow](https://github.com/The-Pocket/PocketFlow) by The Pocket,
> redesigned around Elixir idioms: explicit data threading, `Behaviour`-based nodes,
> and a pure orchestration loop built from the ground up for OTP supervision.

---

## Table of Contents

- [Why Phlox](#why-phlox)
- [Installation](#installation)
- [Core Concept: The Graph](#core-concept-the-graph)
- [Your First Flow](#your-first-flow)
- [Node Lifecycle In Depth](#node-lifecycle-in-depth)
- [Routing and Branching](#routing-and-branching)
- [Retry Logic](#retry-logic)
- [Batch Processing](#batch-processing)
- [Fan-Out: Mid-Flow Sub-Flows](#fan-out-mid-flow-sub-flows)
- [The DSL](#the-dsl)
- [OTP: Supervised Flows](#otp-supervised-flows)
- [Real-Time Monitoring](#real-time-monitoring)
- [Adapters: Phoenix and Datastar](#adapters-phoenix-and-datastar)
- [Telemetry](#telemetry)
- [Graph Validation](#graph-validation)
- [Design Patterns](#design-patterns)
- [Testing Your Nodes](#testing-your-nodes)
- [For AI Agents: Complete API Reference](#for-ai-agents-complete-api-reference)
- [Roadmap](#roadmap)
- [Attribution](#attribution)

---

## Why Phlox

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
| Step-through debugging | ✗ | ✗ | ✓ |
| Real-time monitoring | ✗ | ✗ | ✓ |
| Mutable shared state | ✓ | ✓ | ✗ (explicit threading) |
| Node isolation | ✗ | ✗ | ✓ |
| Zero required runtime deps | ✗ | ✗ | ✓ |

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:phlox, "~> 0.2"},

    # Optional — enables [:phlox, :flow | :node, :*] telemetry events
    # and powers Phlox.Monitor
    {:telemetry, "~> 1.0"},

    # Optional — enables Phlox.Adapter.Phoenix + FlowMonitor LiveComponent
    {:phoenix_live_view, "~> 1.0"},

    # Optional — enables Phlox.Adapter.Datastar SSE streaming
    {:datastar, "~> 0.1"},  # the datastar_ex SDK
    {:jason,    "~> 1.4"},  # required by the Datastar SDK
  ]
end
```

Phlox has **zero required runtime dependencies**. Adapters and monitoring
activate automatically when their deps are present — no configuration needed.

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

### Step 1 — Define nodes

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

  def exec(body, _params) do
    body |> String.split(~r/\s+/, trim: true) |> length()
  end

  def post(shared, _prep, count, _params) do
    {:default, Map.put(shared, :word_count, count)}
  end
end
```

### Step 2 — Wire the graph

```elixir
alias Phlox.Graph

flow =
  Graph.new()
  |> Graph.add_node(:fetch,  MyApp.FetchNode,     %{}, max_retries: 3)
  |> Graph.add_node(:count,  MyApp.WordCountNode,  %{})
  |> Graph.add_node(:error,  MyApp.ErrorNode,      %{})
  |> Graph.connect(:fetch, :count)
  |> Graph.connect(:fetch, :error, action: "error")
  |> Graph.start_at(:fetch)
  |> Graph.to_flow!()
```

### Step 3 — Run it

```elixir
{:ok, result} = Phlox.run(flow, %{url: "https://example.com"})
IO.puts("Word count: #{result.word_count}")
```

---

## Node Lifecycle In Depth

Every node runs three phases. Understanding them is the key to using Phlox well.

```
shared ──▶ prep(shared, params)
                │
                ▼ prep_res
           exec(prep_res, params)   ◀── retry loop wraps this
                │
                ▼ exec_res
           post(shared, prep_res, exec_res, params)
                │
                ▼ {action, new_shared}
```

### `prep/2` — Read shared state

Reads from `shared`, returns data for `exec`. Pure — no side effects.

```elixir
def prep(shared, params) do
  %{
    text:     Map.fetch!(shared, :text),
    language: Map.get(params, :language, "en")
  }
end
```

**Why separate from exec?** Because `exec` has no access to `shared`. This
clean separation means `exec` is independently testable — just call it directly
with any input and verify the output.

### `exec/2` — Do the work

All I/O lives here: HTTP calls, DB queries, LLM requests, pure computation.
May raise; Phlox will retry up to `max_retries` times.

```elixir
def exec(%{text: text, language: lang}, _params) do
  MyLLM.translate(text, to: lang)
end
```

### `post/4` — Update state and route

Decides the next action and updates shared state. Pattern-match on `exec_res`
to implement branching.

```elixir
def post(shared, _prep, {:ok, translation}, _params) do
  {:default, Map.put(shared, :translation, translation)}
end

def post(shared, _prep, {:error, :rate_limited}, _params) do
  {"retry_later", Map.put(shared, :retry_at, DateTime.utc_now())}
end

def post(shared, _prep, {:error, reason}, _params) do
  {"error", Map.put(shared, :error, reason)}
end
```

Return `:default` or `"default"` for the normal forward path.

### `exec_fallback/3` — Handle exhausted retries

Called when `exec/2` raises and all retries are exhausted. Default re-raises.
Override to degrade gracefully:

```elixir
def exec_fallback(_prep_res, _exception, params) do
  # Return a cached value instead of crashing the flow
  {:ok, Map.fetch!(params, :fallback_body)}
end
```

---

## Routing and Branching

Branches are pattern-matched `post/4` clauses returning different action strings.

```elixir
defmodule MyApp.RouterNode do
  use Phlox.Node

  def prep(shared, _p), do: Map.fetch!(shared, :request_type)
  def exec(type, _p),   do: type

  def post(shared, _p, :summarise, _p2), do: {"summarise", shared}
  def post(shared, _p, :translate, _p2), do: {"translate", shared}
  def post(shared, _p, _unknown,   _p2), do: {"error",     shared}
end

flow =
  Graph.new()
  |> Graph.add_node(:router,    MyApp.RouterNode,    %{})
  |> Graph.add_node(:summarise, MyApp.SummariseNode, %{})
  |> Graph.add_node(:translate, MyApp.TranslateNode, %{})
  |> Graph.add_node(:error,     MyApp.ErrorNode,     %{})
  |> Graph.connect(:router, :summarise, action: "summarise")
  |> Graph.connect(:router, :translate, action: "translate")
  |> Graph.connect(:router, :error,     action: "error")
  |> Graph.start_at(:router)
  |> Graph.to_flow!()
```

---

## Retry Logic

Configure per node. Default is `max_retries: 1` (one attempt, no retry).

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

### Sequential batch

Implement `exec_one/2` instead of `exec/2`. `prep/2` returns the list.

```elixir
defmodule MyApp.TranslateManyNode do
  use Phlox.BatchNode  # parallel: false by default

  def prep(shared, _p), do: Map.fetch!(shared, :texts)

  def exec_one(text, params), do: MyLLM.translate(text, to: params.target_language)

  def post(shared, _prep, translations, _p) do
    {:default, Map.put(shared, :translations, translations)}
  end
end
```

### Parallel batch

Add `parallel: true`. Results are always returned in input order.

```elixir
defmodule MyApp.FetchManyNode do
  use Phlox.BatchNode, parallel: true, max_concurrency: 10, timeout: 15_000

  def prep(shared, _p), do: Map.fetch!(shared, :urls)
  def exec_one(url, _p), do: HTTPoison.get!(url).body

  def exec_fallback_one(url, _exc, _p), do: {:error, "failed: #{url}"}

  def post(shared, _prep, results, _p) do
    {:default, Map.put(shared, :bodies, results)}
  end
end
```

Use `exec_fallback_one/3` to handle individual item failures without
stopping the entire batch.

### Batch flows

Run an entire inner flow once per item in a list, with param overrides per run.

```elixir
defmodule MyApp.DocumentBatch do
  use Phlox.BatchFlow, parallel: true

  def prep(shared) do
    Enum.map(shared.documents, fn doc ->
      %{document_id: doc.id, text: doc.content}
    end)
  end
end

inner_flow = build_inner_flow()
{:ok, results} = MyApp.DocumentBatch.run(inner_flow, %{documents: docs})
```

With `parallel: false` (default), each run receives the accumulated `shared`
from the previous run. With `parallel: true`, all runs receive the same
initial `shared` and results are collected as a list.

---

## Fan-Out: Mid-Flow Sub-Flows

`Phlox.FanOutNode` fans out over a list mid-flow, running a complete sub-flow
per item, then merges results back. This is the difference from `BatchNode`
(single `exec_one` call) — each item gets a full multi-node pipeline.

```elixir
defmodule MyApp.EmbedChunksNode do
  use Phlox.FanOutNode, parallel: true

  # Returns the list to fan over
  def fan_out_prep(shared, _p), do: shared.chunks

  # The sub-flow each item runs through
  def sub_flow(_p) do
    Graph.new()
    |> Graph.add_node(:clean,  MyApp.CleanNode,  %{})
    |> Graph.add_node(:embed,  MyApp.EmbedNode,  %{model: "ada-002"})
    |> Graph.connect(:clean, :embed)
    |> Graph.start_at(:clean)
    |> Graph.to_flow!()
  end

  # Map one item to a shared map for its sub-flow run
  def item_to_shared(chunk, parent_shared, _p) do
    Map.merge(parent_shared, %{text: chunk.text, chunk_id: chunk.id})
  end

  # Collect all sub-flow results back into parent shared
  def merge(shared, results, _p) do
    embeddings = Enum.map(results, & &1.embedding)
    {:default, Map.put(shared, :embeddings, embeddings)}
  end
end
```

| Callback | Default | Purpose |
|---|---|---|
| `fan_out_prep/2` | returns `[]` | produce the list of items |
| `sub_flow/1` | required | the flow each item runs through |
| `item_to_shared/3` | `Map.put(shared, :item, item)` | map item → sub-flow shared |
| `merge/3` | puts results under `:fan_out_results` | collect results → parent shared |

Options: `parallel:`, `max_concurrency:`, `timeout:` — same as `BatchNode`.

---

## The DSL

`Phlox.DSL` turns any module into a flow declaration. No builder pipeline needed.

```elixir
defmodule MyApp.IngestFlow do
  use Phlox.DSL

  node :fetch,  MyApp.FetchNode,  %{},              max_retries: 3
  node :parse,  MyApp.ParseNode,  %{schema: :json}
  node :store,  MyApp.StoreNode,  %{}
  node :error,  MyApp.ErrorNode,  %{}

  connect :fetch, :parse
  connect :fetch, :error,  action: "error"
  connect :parse, :store
  connect :parse, :error,  action: "error"

  start_at :fetch
end
```

**Generated functions:**

```elixir
# Returns a validated %Phlox.Flow{} — raises ArgumentError on invalid graph
flow = MyApp.IngestFlow.flow()

# Run directly — shortcut for Phlox.run(flow(), shared)
{:ok, result} = MyApp.IngestFlow.run(%{url: "https://example.com"})

# Compose with FlowSupervisor
Phlox.FlowSupervisor.start_flow(:ingest, MyApp.IngestFlow.flow(), shared)
```

Cache the flow at compile time to avoid rebuilding on every call:

```elixir
@flow MyApp.IngestFlow.flow()   # raises at compile time if graph is invalid
```

---

## OTP: Supervised Flows

### FlowServer

`Phlox.FlowServer` wraps a flow in a `GenServer`:

```elixir
{:ok, pid} = Phlox.FlowServer.start_link(flow: my_flow, shared: %{url: "..."})

# Run to completion (blocks until done)
{:ok, final_shared} = Phlox.FlowServer.run(pid)

# Step one node at a time
{:continue, :parse, shared} = Phlox.FlowServer.step(pid)
{:continue, :store, shared} = Phlox.FlowServer.step(pid)
{:done,     final_shared}   = Phlox.FlowServer.step(pid)

# Inspect at any point
%{shared: s, current_id: node, status: status} = Phlox.FlowServer.state(pid)

# Reset and re-run
:ok = Phlox.FlowServer.reset(pid, %{url: "https://other.com"})
{:ok, result} = Phlox.FlowServer.run(pid)
```

Status machine: `:ready → :running | :stepping → :done | {:error, exc}`

### FlowSupervisor

`Phlox.FlowSupervisor` is a `DynamicSupervisor` started automatically
by `Phlox.Application`. Spawn named flows at runtime:

```elixir
alias Phlox.{FlowSupervisor, FlowServer}

# Start a flow under supervision
{:ok, _pid} = FlowSupervisor.start_flow(:my_job, flow, %{input: "..."})

# Address by name via FlowSupervisor.server/1
server = FlowSupervisor.server(:my_job)
{:ok, result} = FlowServer.run(server)

# Inspect
%{status: s, current_id: n} = FlowServer.state(server)

# Step through
{:continue, :next_node, shared} = FlowServer.step(server)

# List / check / stop
FlowSupervisor.running()         # => [:my_job, :other_job, ...]
FlowSupervisor.whereis(:my_job)  # => #PID<...> or nil
FlowSupervisor.stop_flow(:my_job)
```

**Restart strategies:**

```elixir
# :temporary (default) — not restarted on crash
FlowSupervisor.start_flow(:job, flow, shared)

# :permanent — restarted automatically (good for long-running agent loops)
FlowSupervisor.start_flow(:agent, flow, shared, restart: :permanent)
```

**Supervisor tuning** (configure in `Application.start/2` or directly):

```elixir
# High-churn short flows
Phlox.FlowSupervisor.start_link(max_restarts: 10, max_seconds: 30)

# Long-running agents that need room to breathe
Phlox.FlowSupervisor.start_link(max_restarts: 50, max_seconds: 300)
```

---

## Real-Time Monitoring

`Phlox.Monitor` is a GenServer that tracks every running flow in ETS.
It starts automatically and attaches to telemetry events.

### Querying

```elixir
# Current snapshot for a specific flow
snapshot = Phlox.Monitor.get("my-flow-id")
# => %{
#   flow_id:     "my-flow-id",
#   status:      :running,
#   start_id:    :fetch,
#   current_id:  :embed,
#   started_at:  ~U[2026-04-05 ...],
#   updated_at:  ~U[2026-04-05 ...],
#   nodes: %{
#     fetch: %{status: :done, duration_ms: 142, started_at: ..., stopped_at: ...},
#     embed: %{status: :running, duration_ms: nil, started_at: ..., stopped_at: nil}
#   }
# }

# All tracked flows
Phlox.Monitor.list()
```

### Subscribing

```elixir
# Calling process receives {:phlox_monitor, event, snapshot} messages
:ok = Phlox.Monitor.subscribe("my-flow-id")

# Events: :flow_started, :node_started, :node_done, :node_error,
#         :flow_done, :flow_error, :flow_expired

receive do
  {:phlox_monitor, :node_done, snapshot} ->
    IO.puts("#{snapshot.current_id} took #{snapshot.nodes[:fetch].duration_ms}ms")
end

# Unsubscribe
:ok = Phlox.Monitor.unsubscribe("my-flow-id")
```

Subscriptions are automatically cleaned up when the subscriber process exits.

### Stable flow IDs

By default, each `Flow.run/2` gets a unique `make_ref()`. Supply a
human-readable ID for log correlation:

```elixir
Phlox.run(flow, %{phlox_flow_id: "ingest-job-" <> job_id})
```

### TTL

Snapshots are retained for 5 minutes after a flow completes (configurable):

```elixir
# In your Application or supervision tree
Phlox.Monitor.start_link(ttl_ms: :timer.minutes(30))
```

---

## Adapters: Phoenix and Datastar

Both adapters read from `Phlox.Monitor` and are transport-agnostic at their
core. A Phoenix app using Datastar for its frontend can run both simultaneously.

### Phlox.Adapter.Phoenix

Requires `phoenix_live_view`. Two integration options:

**Option A — `use` mixin (bring monitoring into your own LiveView):**

```elixir
defmodule MyAppWeb.JobLive do
  use MyAppWeb, :live_view
  use Phlox.Adapter.Phoenix

  def mount(%{"flow_id" => flow_id}, _session, socket) do
    {:ok, phlox_subscribe(socket, flow_id)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <span>Status: {@phlox_status}</span>
      <span>Current: {@phlox_current_node}</span>
      <%= for {id, node} <- @phlox_nodes do %>
        <div class={node_class(node.status)}>
          <%= id %>: <%= node.duration_ms || "running..." %>ms
        </div>
      <% end %>
    </div>
    """
  end

  # Optional — react to specific events
  def handle_phlox_event(:flow_done, _snapshot, socket) do
    {:noreply, put_flash(socket, :info, "Job complete!")}
  end
end
```

**Assigns available after `phlox_subscribe/2`:**

| Assign | Type | Description |
|---|---|---|
| `@phlox_flow_id` | `term()` | the subscribed flow ID |
| `@phlox_status` | `:ready \| :running \| :done \| {:error, exc}` | flow status |
| `@phlox_current_node` | `atom() \| nil` | node executing now |
| `@phlox_nodes` | `%{atom() => map()}` | per-node status + timing |
| `@phlox_started_at` | `DateTime.t() \| nil` | when the flow started |

**Option B — drop-in LiveComponent:**

```heex
<.live_component
  module={Phlox.Adapter.Phoenix.FlowMonitor}
  id={"monitor-#{@flow_id}"}
  flow_id={@flow_id}
/>
```

Renders a self-updating status table. Pass `:render_fn` for custom rendering.

### Phlox.Adapter.Datastar

Requires the `datastar_ex` SDK and `plug`. Works with Bandit, Cowboy, or Phoenix.

**Router setup:**

```elixir
# Phoenix router
get "/phlox/stream/:flow_id", Phlox.Adapter.Datastar.Plug, []

# Plain Plug.Router
forward "/phlox/stream", to: Phlox.Adapter.Datastar.Plug

# Or call stream/2 directly from any Plug handler
def call(%{path_info: ["stream", flow_id]} = conn, _opts) do
  Phlox.Adapter.Datastar.stream(conn, flow_id)
end
```

**Frontend (zero JS beyond Datastar):**

```html
<div data-signals="{'phlox_status': 'ready', 'phlox_current_node': ''}">
  <!-- Open SSE stream on page load -->
  <div data-on-load="@get('/phlox/stream/my-flow-id')"></div>

  <!-- Reactive status badge -->
  <span data-text="$phlox_status"
        data-class:running="$phlox_status === 'running'"
        data-class:done="$phlox_status === 'done'">
  </span>

  <!-- Node list — Phlox patches rows in as nodes execute -->
  <div id="phlox-nodes"></div>
</div>
```

**Signals emitted:**

| Signal | Type | Value |
|---|---|---|
| `$phlox_status` | string | `"ready"` / `"running"` / `"done"` / `"error"` |
| `$phlox_current_node` | string | atom string of running node, or `""` |
| `$phlox_started_at` | string | ISO8601 or `""` |
| `$phlox_node_{id}_status` | string | per-node status string |
| `$phlox_node_{id}_duration_ms` | integer / null | per-node duration |

---

## Telemetry

Phlox emits telemetry events when `:telemetry` is present. When it's absent,
all emit paths compile to no-ops with zero runtime overhead.

| Event | Measurements | When |
|---|---|---|
| `[:phlox, :flow, :start]` | `system_time` | `Flow.run/2` begins |
| `[:phlox, :flow, :stop]` | `duration` | flow finishes (ok or error) |
| `[:phlox, :node, :start]` | `system_time` | before `prep/2` |
| `[:phlox, :node, :stop]` | `duration` | after `post/4` returns |
| `[:phlox, :node, :exception]` | `duration` | node raises after all retries |

All events include `flow_id`, `node_id`, and `module` in metadata.

```elixir
:telemetry.attach_many("myapp-phlox", [
  [:phlox, :flow, :start],
  [:phlox, :flow, :stop],
  [:phlox, :node, :start],
  [:phlox, :node, :stop],
  [:phlox, :node, :exception]
], &MyApp.PhloxHandler.handle/4, nil)
```

---

## Graph Validation

`Graph.to_flow/1` validates the graph before you ever run it:

```elixir
case Graph.to_flow(builder) do
  {:ok, flow}    -> Phlox.run(flow, shared)
  {:error, msgs} -> Enum.each(msgs, &IO.puts/1)
end

# Or raise immediately
flow = Graph.to_flow!(builder)
```

Caught at build time: no start node, unknown successor references,
overwritten connections (warning, not error).

---

## Design Patterns

### Simple Pipeline

```elixir
defmodule MyApp.IngestFlow do
  use Phlox.DSL

  node :fetch, FetchNode, %{source: :web}, max_retries: 3
  node :clean, CleanNode, %{strip_html: true}
  node :embed, EmbedNode, %{model: "ada-002"}
  node :store, StoreNode, %{table: "docs"}
  node :error, ErrorNode, %{}

  connect :fetch, :clean
  connect :fetch, :error, action: "error"
  connect :clean, :embed
  connect :embed, :store

  start_at :fetch
end
```

### Agent Loop (ReAct-style)

```elixir
defmodule MyAgent.ThinkNode do
  use Phlox.Node

  def prep(shared, _p), do: {shared.goal, Map.get(shared, :history, [])}

  def exec({goal, history}, params) do
    MyLLM.call(build_prompt(goal, history), params)
  end

  def post(shared, _p, %{"action" => action, "done" => true}, _p2) do
    {"done", Map.put(shared, :final_answer, action)}
  end

  def post(shared, _p, %{"action" => action}, _p2) do
    history = Map.get(shared, :history, [])
    {"continue", shared |> Map.put(:next_action, action)
                        |> Map.put(:history, history ++ [action])}
  end
end

defmodule MyApp.AgentFlow do
  use Phlox.DSL

  node :think,  MyAgent.ThinkNode,  %{model: "claude-opus-4"}, max_retries: 2
  node :act,    MyAgent.ActNode,    %{}
  node :finish, MyAgent.FinishNode, %{}

  connect :think, :act,    action: "continue"
  connect :think, :finish, action: "done"
  connect :act,   :think   # loop back

  start_at :think
end

{:ok, result} = MyApp.AgentFlow.run(%{goal: "Research quantum computing trends"})
```

### RAG (Retrieval-Augmented Generation)

```elixir
defmodule MyApp.RAGFlow do
  use Phlox.DSL

  node :embed_query, MyApp.EmbedQueryNode, %{}
  node :search,      MyApp.SearchNode,     %{top_k: 5}
  node :generate,    MyApp.GenerateNode,   %{model: "claude-sonnet-4"}

  connect :embed_query, :search
  connect :search,      :generate

  start_at :embed_query
end

{:ok, result} = MyApp.RAGFlow.run(%{question: "What is event sourcing?"})
IO.puts(result.answer)
```

### Map-Reduce over a List

```elixir
defmodule MyApp.SummariseManyNode do
  use Phlox.BatchNode, parallel: true, max_concurrency: 5

  def prep(shared, _p), do: shared.documents
  def exec_one(doc, params), do: MyLLM.summarise(doc.text, params)

  def post(shared, _prep, summaries, _p) do
    {:default, Map.put(shared, :summaries, summaries)}
  end
end

defmodule MyApp.SynthesiseNode do
  use Phlox.Node

  def prep(shared, _p), do: shared.summaries

  def exec(summaries, params) do
    combined = Enum.join(summaries, "\n\n---\n\n")
    MyLLM.call("Synthesise these into one:\n#{combined}", params)
  end

  def post(shared, _p, synthesis, _p2) do
    {:default, Map.put(shared, :synthesis, synthesis)}
  end
end
```

### Multi-Agent Handoff

```elixir
defmodule MyApp.CoordinatorNode do
  use Phlox.Node

  def prep(shared, _p), do: shared.task
  def exec(task, _p),   do: MyLLM.classify_task(task)

  def post(shared, _p, :research, _p2), do: {"research", shared}
  def post(shared, _p, :write,    _p2), do: {"write",    shared}
  def post(shared, _p, :code,     _p2), do: {"code",     shared}
end

# Each specialist is a sub-flow wrapped in a FanOutNode or delegate node
defmodule MyApp.CoordinatorFlow do
  use Phlox.DSL

  node :coord,    MyApp.CoordinatorNode,   %{}
  node :research, MyApp.ResearchDelegate,  %{}
  node :write,    MyApp.WriteDelegate,     %{}
  node :code,     MyApp.CodeDelegate,      %{}

  connect :coord, :research, action: "research"
  connect :coord, :write,    action: "write"
  connect :coord, :code,     action: "code"

  start_at :coord
end
```

---

## Testing Your Nodes

Because `exec/2` has no access to `shared`, nodes are trivially testable in isolation:

```elixir
defmodule MyApp.TranslateNodeTest do
  use ExUnit.Case, async: true

  # Test exec directly — no flow, no graph, no shared state needed
  test "translates text to target language" do
    result = MyApp.TranslateNode.exec(%{text: "hello", language: "fr"}, %{})
    assert result == {:ok, "bonjour"}
  end

  # Test routing logic in post
  test "routes to :default on success" do
    {action, new_shared} =
      MyApp.TranslateNode.post(%{}, nil, {:ok, "bonjour"}, %{})

    assert action == :default
    assert new_shared.translation == "bonjour"
  end

  test "routes to 'error' on failure" do
    {action, new_shared} =
      MyApp.TranslateNode.post(%{}, nil, {:error, "unsupported"}, %{})

    assert action == "error"
    assert new_shared.error == "unsupported"
  end
end
```

For integration tests, build a real flow with stub nodes:

```elixir
defmodule MyApp.PipelineTest do
  use ExUnit.Case, async: true

  defmodule StubFetchNode do
    use Phlox.Node
    def exec(_url, _p), do: "mocked body"
    def post(shared, _p, body, _p2), do: {:default, Map.put(shared, :body, body)}
  end

  test "pipeline stores word count" do
    flow =
      Phlox.Graph.new()
      |> Phlox.Graph.add_node(:fetch, StubFetchNode,        %{})
      |> Phlox.Graph.add_node(:count, MyApp.WordCountNode,  %{})
      |> Phlox.Graph.connect(:fetch, :count)
      |> Phlox.Graph.start_at(:fetch)
      |> Phlox.Graph.to_flow!()

    {:ok, result} = Phlox.run(flow, %{url: "http://stub"})
    assert result.word_count == 2
  end
end
```

For Monitor-dependent tests, use `handle_telemetry_event/4` directly — no
`:telemetry` dep required:

```elixir
Phlox.Monitor.handle_telemetry_event(
  [:phlox, :flow, :start],
  %{system_time: System.system_time()},
  %{flow_id: "test-1", start_id: :fetch},
  nil
)
Process.sleep(30)  # cast is async
snapshot = Phlox.Monitor.get("test-1")
```

---

## For AI Agents: Complete API Reference

This section is a compact, precise reference for AI agents working with Phlox.
Everything needed to generate correct Phlox code is here.

### Module map

```
Phlox                        top-level: run/2, graph/0
Phlox.Node                   behaviour + __using__ macro
Phlox.BatchNode              __using__ macro, exec_one/2 per item
Phlox.FanOutNode             __using__ macro, sub_flow per item
Phlox.BatchFlow              __using__ macro, full-flow fan-out
Phlox.DSL                    __using__ macro, declarative flow definition
Phlox.Graph                  builder: new/add_node/connect/start_at/to_flow[!]
Phlox.Flow                   %Flow{} struct + run/2
Phlox.Runner                 orchestrate/4 (pure, no OTP)
Phlox.Retry                  run/2 (pure, extracted)
Phlox.FlowServer             GenServer: run/step/state/reset
Phlox.FlowSupervisor         DynamicSupervisor: start_flow/stop_flow/whereis/running/server
Phlox.Monitor                GenServer+ETS: get/list/subscribe/unsubscribe
Phlox.Telemetry              soft-dep telemetry emission
Phlox.Adapter.Phoenix        use mixin + phlox_subscribe/2
Phlox.Adapter.Phoenix.FlowMonitor  LiveComponent
Phlox.Adapter.Datastar       stream/2
Phlox.Adapter.Datastar.Plug  Plug behaviour
```

### Phlox.Node callbacks

```elixir
# All have default no-op implementations. Only override what you need.

@callback prep(shared :: map(), params :: map()) :: term()
# Default: returns nil
# Purpose: read from shared, produce input for exec

@callback exec(prep_res :: term(), params :: map()) :: term()
# Default: returns prep_res unchanged
# Purpose: do the work — I/O, LLM calls, computation. NO access to shared.
# May raise — retry loop wraps this

@callback exec_fallback(prep_res :: term(), exc :: Exception.t(), params :: map()) :: term()
# Default: re-raises exc
# Called: when all max_retries are exhausted

@callback post(shared :: map(), prep_res :: term(), exec_res :: term(), params :: map())
            :: {action :: String.t() | :default, new_shared :: map()}
# Default: returns {:default, shared}
# Purpose: route to next node + update shared state
# Return :default or "default" for the normal path
```

### Phlox.BatchNode callbacks

```elixir
# use Phlox.BatchNode, parallel: false | true,
#                      max_concurrency: integer(),
#                      timeout: integer()

@callback exec_one(item :: term(), params :: map()) :: term()
# Called once per item in the list returned by prep/2

@callback exec_fallback_one(item :: term(), exc :: Exception.t(), params :: map()) :: term()
# Called per item when exec_one raises. Default: re-raises.

# prep/2 and post/4 are inherited from Phlox.Node with same signatures
# post/4 receives the full list of results as exec_res
```

### Phlox.FanOutNode callbacks

```elixir
# use Phlox.FanOutNode, parallel: false | true,
#                       max_concurrency: integer(),
#                       timeout: integer()

@callback fan_out_prep(shared :: map(), params :: map()) :: [term()]
# Default: returns []
# Returns the list of items to fan over

@callback sub_flow(params :: map()) :: Phlox.Flow.t()
# Required — the flow each item runs through

@callback item_to_shared(item :: term(), parent_shared :: map(), params :: map()) :: map()
# Default: Map.put(parent_shared, :item, item)
# Maps one item to the shared map for its sub-flow run

@callback merge(parent_shared :: map(), results :: [map()], params :: map())
            :: {String.t() | :default, map()}
# Default: {:default, Map.put(shared, :fan_out_results, results)}
# Collects sub-flow results back into parent shared
```

### Phlox.DSL macros

```elixir
use Phlox.DSL

node id, module, params \\ %{}, opts \\ []
# opts: max_retries: integer(), wait_ms: integer()

connect from_id, to_id, opts \\ []
# opts: action: string() (default "default")

start_at id

# Generated: flow/0, run/1
```

### Phlox.Graph builder

```elixir
Graph.new()                                           # :: Builder.t()
Graph.add_node(b, id, module, params \\ %{}, opts)   # :: Builder.t()
Graph.connect(b, from_id, to_id, opts \\ [])          # :: Builder.t()
Graph.start_at(b, id)                                 # :: Builder.t()
Graph.to_flow(b)                                      # :: {:ok, Flow.t()} | {:error, [String.t()]}
Graph.to_flow!(b)                                     # :: Flow.t() | raises ArgumentError

# add_node opts: max_retries: integer(), wait_ms: integer()
# connect opts: action: string()
```

### Phlox.Flow

```elixir
Phlox.run(flow, shared \\ %{})
# => {:ok, final_shared} | {:error, Exception.t()}
# Emits [:phlox, :flow, :start | :stop] telemetry

Phlox.Flow.run(flow, shared \\ %{})
# Same as above — Phlox.run/2 delegates here
```

### Phlox.FlowServer

```elixir
FlowServer.start_link(flow: flow, shared: shared, name: via_or_name)
# => {:ok, pid}

FlowServer.run(server)
# => {:ok, final_shared} | {:error, exc} | {:error, {:invalid_status, status}}

FlowServer.step(server)
# => {:continue, next_node_id, current_shared}
#  | {:done, final_shared}
#  | {:error, exc}

FlowServer.state(server)
# => %{shared: map(), current_id: atom() | nil, status: term()}

FlowServer.reset(server, new_shared \\ nil)
# => :ok
# nil restores original shared
```

### Phlox.FlowSupervisor

```elixir
FlowSupervisor.start_link(opts \\ [])
# opts: max_restarts: int(), max_seconds: int(), name: atom()

FlowSupervisor.start_flow(name, flow, shared \\ %{}, opts \\ [])
# opts: restart: :temporary (default) | :permanent | :transient
# => {:ok, pid} | {:error, {:already_started, pid}} | {:error, reason}

FlowSupervisor.stop_flow(name)
# => :ok | {:error, :not_found}
# Blocks until process is fully down

FlowSupervisor.server(name)
# => {:via, Registry, {Phlox.FlowRegistry, name}}
# Use this as the server arg to FlowServer.run/step/state/reset

FlowSupervisor.whereis(name)   # => pid() | nil
FlowSupervisor.running()       # => [name()]
```

### Phlox.Monitor

```elixir
Monitor.subscribe(flow_id)     # => :ok
Monitor.unsubscribe(flow_id)   # => :ok
Monitor.get(flow_id)           # => snapshot_map() | nil
Monitor.list()                 # => [snapshot_map()]

# Messages received after subscribe:
{:phlox_monitor, event, snapshot}
# event: :flow_started | :node_started | :node_done | :node_error
#       | :flow_done | :flow_error | :flow_expired

# Snapshot shape:
%{
  flow_id:     term(),
  status:      :running | :done | {:error, term()},
  start_id:    atom(),
  current_id:  atom() | nil,
  started_at:  DateTime.t(),
  updated_at:  DateTime.t(),
  nodes: %{
    node_id => %{
      status:      :running | :done | {:error, term()},
      started_at:  DateTime.t(),
      stopped_at:  DateTime.t() | nil,
      duration_ms: non_neg_integer() | nil
    }
  }
}
```

### Key invariants AI agents must know

1. **`exec/2` has NO access to `shared`** — only what `prep/2` returned.
   Reading `shared` in `exec` is a pattern violation.

2. **`post/4` must always return `{action, new_shared}`** — never just an
   action string, never just a new_shared map.

3. **Nodes are stateless modules** — no process, no GenServer, no struct.
   State lives exclusively in `shared`.

4. **`connect/3` with no `action:` opt defaults to `"default"`** — matches
   `:default` or `"default"` returned from `post/4`.

5. **`FlowSupervisor.server/1` is required** when addressing named flows —
   `FlowServer.run(:my_name)` will not work; use
   `FlowServer.run(FlowSupervisor.server(:my_name))`.

6. **`Graph.to_flow!/1` raises at call site** — call it in `Application.start/2`
   or module body (`@flow MyFlow.flow()`) to get compile-time-ish validation.

7. **`shared` key `:phlox_flow_id`** is reserved — Phlox reads it for telemetry
   and Monitor correlation. Dont use it for your own data.

8. **`Phlox.Monitor` requires `:telemetry`** to receive live events. Without it,
   `subscribe/1` works but no events are ever delivered (Monitor warns on start).

---

## Roadmap

| Version | Feature | Description |
|---|---|---|
| V2.7 | **Persistent flow state** | Ecto integration — checkpoint `shared` to DB after each node; flows survive restarts and are resumable |
| V2.8 | **Typed shared state** | Norm for node-boundary contracts; optional Ecto.Changeset for flow-entry validation from external sources |

---

## Attribution

Phlox is a port of **[PocketFlow](https://github.com/The-Pocket/PocketFlow)**
by [The Pocket](https://github.com/The-Pocket), originally written in Python.
PocketFlow's three-phase node lifecycle (`prep → exec → post`), graph wiring
model, and batch flow pattern are the direct inspiration for this library.

The Elixir design — explicit data threading, OTP supervision, behaviour-based
nodes, `FlowServer`, `FlowSupervisor`, `Monitor`, real-time adapters, and
telemetry — is Phlox's own contribution.

---

## License

MIT
