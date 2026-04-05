# 🌸 Phlox

**A lightweight, OTP-ready graph execution engine for Elixir — built for AI agent pipelines.**

> Phlox is an Elixir port of [PocketFlow](https://github.com/The-Pocket/PocketFlow) by The Pocket,
> redesigned around Elixir idioms: explicit data threading, `Behaviour`-based nodes,
> and a pure orchestration loop built from the ground up for GenServer wrapping.

---

```
Current LLM frameworks are bloated.
You only need one clean abstraction: a graph.
```

Phlox gives you that graph — plus OTP supervision, retry logic, batch processing,
step-through debugging, and telemetry — in a library that fits comfortably in your head.

---

## Table of Contents

- [Why Phlox?](#why-phlox)
- [Installation](#installation)
- [Core Concept: The Graph](#core-concept-the-graph)
- [Your First Flow](#your-first-flow)
- [Node Lifecycle In Depth](#node-lifecycle-in-depth)
  - [prep/2 — Read shared state](#prep2--read-shared-state)
  - [exec/2 — Do the work](#exec2--do-the-work)
  - [post/4 — Update state and route](#post4--update-state-and-route)
  - [exec_fallback/3 — Handle failure](#exec_fallback3--handle-failure)
- [Routing and Branching](#routing-and-branching)
- [Retry Logic](#retry-logic)
- [Batch Processing](#batch-processing)
  - [Sequential Batches](#sequential-batches)
  - [Parallel Batches](#parallel-batches)
  - [Batch Flows](#batch-flows)
- [OTP: Supervised Flows](#otp-supervised-flows)
  - [FlowServer — Run, Step, Inspect](#flowserver--run-step-inspect)
  - [FlowSupervisor — Named, Supervised Flows](#flowsupervisor--named-supervised-flows)
- [Telemetry](#telemetry)
- [Graph Validation](#graph-validation)
- [Design Patterns](#design-patterns)
  - [Simple Pipeline](#simple-pipeline)
  - [Agent Loop](#agent-loop)
  - [RAG (Retrieval-Augmented Generation)](#rag-retrieval-augmented-generation)
  - [Map-Reduce over a List](#map-reduce-over-a-list)
  - [Multi-Agent Handoff](#multi-agent-handoff)
- [Testing Your Nodes](#testing-your-nodes)
- [V2 Roadmap](#v2-roadmap)
- [Attribution](#attribution)

---

## Why Phlox?

Most LLM orchestration frameworks make three mistakes:

1. **Too much magic.** Implicit state, hidden retries, framework-owned HTTP clients.
2. **Not enough OTP.** No supervision, no fault tolerance, no introspection.
3. **Hard to test.** Nodes are tangled with the graph; you can't test them in isolation.

Phlox fixes all three. A node is just a module. The graph is just a map. State is just
a map passed by value. Every node is independently testable. Every flow is supervisable.

| | LangChain | CrewAI | Phlox |
|---|---|---|---|
| Core abstraction | Chain/Agent | Crew/Task | Graph of nodes |
| Elixir-native | ✗ | ✗ | ✓ |
| OTP supervision | ✗ | ✗ | ✓ |
| Step-through debugging | ✗ | ✗ | ✓ |
| Mutable shared state | ✓ | ✓ | ✗ (explicit threading) |
| Node isolation | ✗ | ✗ | ✓ |
| Zero runtime deps | ✗ | ✗ | ✓ |

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:phlox, "~> 0.1"},

    # Optional — enables [:phlox, :node | :flow, :*] telemetry events
    {:telemetry, "~> 1.0"}
  ]
end
```

```bash
mix deps.get
```

Phlox has **zero required runtime dependencies**. It's pure Elixir + OTP.

---

## Core Concept: The Graph

Everything in Phlox is a **directed graph of nodes**.

```
[FetchNode] ──default──▶ [ParseNode] ──default──▶ [StoreNode]
     │
     └──"error"──▶ [ErrorNode]
```

- **Nodes** are Elixir modules. They receive data, do work, and pass updated data forward.
- **Edges** are action strings. A node's `post/4` returns an action; Phlox follows the
  matching edge to find the next node.
- **Shared state** is a plain `%{}` map. It flows through every node by value — no
  mutation, no hidden state, no surprises.

That's the entire mental model. Everything else is detail.

---

## Your First Flow

Let's build a flow that fetches a URL and counts the words in the response.

### Step 1 — Define your nodes

```elixir
defmodule MyApp.FetchNode do
  use Phlox.Node

  # prep reads from shared state and produces input for exec
  def prep(shared, _params) do
    Map.fetch!(shared, :url)
  end

  # exec does the actual work — no access to shared state
  def exec(url, _params) do
    case HTTPoison.get(url) do
      {:ok, %{status_code: 200, body: body}} -> {:ok, body}
      {:ok, %{status_code: code}}            -> {:error, "HTTP #{code}"}
      {:error, reason}                       -> {:error, inspect(reason)}
    end
  end

  # post decides what happens next and updates shared state
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
    body |> String.split(~r/\s+/, trim: true) |> length()
  end

  def post(shared, _prep_res, count, _params) do
    {:default, Map.put(shared, :word_count, count)}
  end
end

defmodule MyApp.ErrorNode do
  use Phlox.Node

  def post(shared, _prep_res, _exec_res, _params) do
    IO.puts("Flow failed: #{shared[:error]}")
    {:default, Map.put(shared, :failed, true)}
  end
end
```

### Step 2 — Wire the graph

```elixir
alias Phlox.Graph

flow =
  Graph.new()
  |> Graph.add_node(:fetch,  MyApp.FetchNode,      %{})
  |> Graph.add_node(:count,  MyApp.CountWordsNode, %{})
  |> Graph.add_node(:error,  MyApp.ErrorNode,      %{})
  |> Graph.connect(:fetch, :count)                       # default action
  |> Graph.connect(:fetch, :error, action: "error")      # "error" action
  |> Graph.connect(:count, :error, action: "error")
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

```elixir
def prep(shared, params) do
  # Read what exec needs from shared state.
  # Return value becomes the first arg of exec/2.
  # Keep this pure — no side effects.
  %{
    text:     Map.fetch!(shared, :text),
    language: Map.get(params, :language, "en")
  }
end
```

**Why separate from exec?** Because exec can't touch `shared`. This forces a clean
boundary: reading state (prep) is separate from doing work (exec) is separate from
writing state (post). Each phase is independently testable.

### `exec/2` — Do the work

```elixir
def exec(%{text: text, language: lang}, params) do
  # This is where all I/O lives: HTTP calls, DB queries, LLM requests.
  # It has NO access to shared state — only what prep handed it.
  # It can raise; Phlox will retry up to max_retries times.
  MyLLM.translate(text, to: lang)
end
```

**Why no access to `shared`?** Testability. You can call `exec/2` directly in a test
with any input and verify the output, completely independent of any flow or graph:

```elixir
test "translates english to french" do
  result = MyApp.TranslateNode.exec(%{text: "hello", language: "fr"}, %{})
  assert result == "bonjour"
end
```

### `post/4` — Update state and route

```elixir
# Pattern match on exec_res to decide the next action
def post(shared, _prep_res, {:ok, translation}, _params) do
  new_shared = Map.put(shared, :translation, translation)
  {:default, new_shared}    # continue to the next connected node
end

def post(shared, _prep_res, {:error, :rate_limited}, _params) do
  {"retry_later", Map.put(shared, :retry_at, DateTime.utc_now())}
end

def post(shared, _prep_res, {:error, reason}, _params) do
  {"error", Map.put(shared, :error, reason)}
end
```

The action string is matched against the node's successors in the graph.
Use `:default` or `"default"` for the normal forward path.

### `exec_fallback/3` — Handle failure

Called when `exec/2` raises and all retries are exhausted.
Default behaviour is to re-raise. Override to degrade gracefully:

```elixir
def exec_fallback(prep_res, _exception, _params) do
  # Return a safe default instead of crashing the flow
  {:ok, "[translation unavailable]"}
end
```

---

## Routing and Branching

Branches are just pattern-matched `post/4` clauses returning different action strings.

```elixir
# A router node that sends work to different specialists
defmodule MyApp.RouterNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :request_type)

  def exec(type, _params), do: type  # pass-through

  def post(shared, _prep, :summarise,  _params), do: {"summarise", shared}
  def post(shared, _prep, :translate,  _params), do: {"translate", shared}
  def post(shared, _prep, :classify,   _params), do: {"classify",  shared}
  def post(shared, _prep, _unknown,    _params), do: {"error",     shared}
end
```

```elixir
flow =
  Graph.new()
  |> Graph.add_node(:router,    MyApp.RouterNode,    %{})
  |> Graph.add_node(:summarise, MyApp.SummariseNode, %{})
  |> Graph.add_node(:translate, MyApp.TranslateNode, %{model: "opus"})
  |> Graph.add_node(:classify,  MyApp.ClassifyNode,  %{})
  |> Graph.add_node(:error,     MyApp.ErrorNode,     %{})
  |> Graph.connect(:router, :summarise, action: "summarise")
  |> Graph.connect(:router, :translate, action: "translate")
  |> Graph.connect(:router, :classify,  action: "classify")
  |> Graph.connect(:router, :error,     action: "error")
  |> Graph.start_at(:router)
  |> Graph.to_flow!()
```

---

## Retry Logic

Set `max_retries:` per node. Default is `1` (one attempt, no retry).

```elixir
Graph.add_node(:fetch, MyApp.FetchNode, %{}, max_retries: 3, wait_ms: 1000)
```

With `max_retries: 3` and `wait_ms: 1000`:

```
attempt 1 → raises → sleep 1000ms
attempt 2 → raises → sleep 1000ms
attempt 3 → raises → exec_fallback/3 is called
```

Override `exec_fallback/3` to return a safe value rather than re-raising:

```elixir
defmodule MyApp.FetchNode do
  use Phlox.Node

  def exec(url, _params) do
    HTTPoison.get!(url).body
  end

  # After 3 failed attempts, return a cached value
  def exec_fallback(_url, _exc, params) do
    Map.fetch!(params, :fallback_body)
  end
end

# Supply the fallback in params
Graph.add_node(:fetch, MyApp.FetchNode,
  %{fallback_body: "<cached>"},
  max_retries: 3,
  wait_ms: 500
)
```

---

## Batch Processing

### Sequential Batches

Process a list of items one at a time. Implement `exec_one/2` instead of `exec/2`:

```elixir
defmodule MyApp.TranslateManyNode do
  use Phlox.BatchNode  # parallel: false by default

  # prep returns the list of items to process
  def prep(shared, _params) do
    Map.fetch!(shared, :texts)
  end

  # exec_one is called once per item
  def exec_one(text, params) do
    MyLLM.translate(text, to: params.target_language)
  end

  # post receives the full list of results
  def post(shared, _prep_res, translations, _params) do
    {:default, Map.put(shared, :translations, translations)}
  end
end
```

### Parallel Batches

Add `parallel: true` to use `Task.async_stream` under the hood.
Results are always returned in the same order as the input list.

```elixir
defmodule MyApp.FetchManyNode do
  use Phlox.BatchNode, parallel: true, max_concurrency: 10, timeout: 15_000

  def prep(shared, _params), do: Map.fetch!(shared, :urls)

  def exec_one(url, _params) do
    HTTPoison.get!(url).body
  end

  # Handle per-item failure without crashing the batch
  def exec_fallback_one(url, _exc, _params) do
    {:error, "failed to fetch #{url}"}
  end

  def post(shared, _prep_res, results, _params) do
    {:default, Map.put(shared, :bodies, results)}
  end
end
```

Use `exec_fallback_one/3` (note: `_one`) to handle individual item failures
without stopping the entire batch.

### Batch Flows

Run an entire flow multiple times, once per entry in a list of param overrides.
Useful for processing a dataset through a multi-node pipeline:

```elixir
defmodule MyApp.DocumentBatch do
  use Phlox.BatchFlow, parallel: true

  # prep returns a list of param maps — one per flow run
  def prep(shared) do
    Enum.map(shared.documents, fn doc ->
      %{document_id: doc.id, text: doc.content}
    end)
  end
end

# Build the inner flow (processes one document)
inner_flow =
  Graph.new()
  |> Graph.add_node(:classify, MyApp.ClassifyNode, %{})
  |> Graph.add_node(:embed,    MyApp.EmbedNode,    %{model: "ada-002"})
  |> Graph.add_node(:store,    MyApp.StoreNode,    %{})
  |> Graph.connect(:classify, :embed)
  |> Graph.connect(:embed, :store)
  |> Graph.start_at(:classify)
  |> Graph.to_flow!()

# Run the inner flow once per document, in parallel
{:ok, results} = MyApp.DocumentBatch.run(inner_flow, %{documents: docs})
```

---

## OTP: Supervised Flows

### FlowServer — Run, Step, Inspect

`Phlox.FlowServer` wraps a flow in a `GenServer`, giving you:

- **`run/1`** — run all nodes to completion, block until done
- **`step/1`** — advance exactly one node, then pause
- **`state/1`** — inspect `shared` state at any point
- **`reset/2`** — restart with the same or new shared state

```elixir
# Start the server directly
{:ok, pid} = Phlox.FlowServer.start_link(flow: my_flow, shared: %{url: "..."})

# Run to completion
{:ok, final} = Phlox.FlowServer.run(pid)

# Or step through manually — great for debugging
{:continue, :parse, shared}   = Phlox.FlowServer.step(pid)
{:continue, :store, shared}   = Phlox.FlowServer.step(pid)
{:done,     final_shared}     = Phlox.FlowServer.step(pid)

# Inspect state between steps
%{shared: s, current_id: node, status: status} = Phlox.FlowServer.state(pid)

# Reset and re-run
:ok = Phlox.FlowServer.reset(pid, %{url: "https://other.com"})
{:ok, result2} = Phlox.FlowServer.run(pid)
```

**Status machine:**

```
:ready ──run/1──▶ :running ──▶ :done
:ready ──step/1─▶ :stepping ──▶ :done
                        │
                        └──▶ {:error, exception}
```

### FlowSupervisor — Named, Supervised Flows

Add `Phlox.FlowSupervisor` to your application's supervision tree.
It starts automatically with `Phlox.FlowRegistry` when you add `:phlox` to your deps.

```elixir
# lib/my_app/application.ex — already included if you use Phlox normally
children = [
  # Phlox.FlowRegistry and Phlox.FlowSupervisor are started by Phlox.Application
  MyApp.Repo,
  MyAppWeb.Endpoint
]
```

Spawn named flows at runtime:

```elixir
alias Phlox.{FlowSupervisor, FlowServer}

# Spawn a flow under supervision
{:ok, _pid} = FlowSupervisor.start_flow(:ingest_job_42, flow, %{doc_id: 42})

# Address it by name via FlowSupervisor.server/1
server = FlowSupervisor.server(:ingest_job_42)
{:ok, result} = FlowServer.run(server)

# List all running flows
FlowSupervisor.running()
# => [:ingest_job_42, :other_job, ...]

# Check if a specific flow is alive
FlowSupervisor.whereis(:ingest_job_42)
# => #PID<0.123.0>  or  nil

# Stop a flow
FlowSupervisor.stop_flow(:ingest_job_42)
```

**Restart strategies:**

```elixir
# Default: temporary — not restarted if it crashes (correct for most flows)
FlowSupervisor.start_flow(:job, flow, shared)

# Permanent: restarted automatically — good for long-running agent loops
FlowSupervisor.start_flow(:agent, flow, shared, restart: :permanent)
```

---

## Telemetry

Phlox emits telemetry events when `:telemetry` is in your deps. If it's not, all
emit calls are compile-time no-ops with zero runtime overhead.

### Events

| Event | Measurements | When |
|---|---|---|
| `[:phlox, :flow, :start]` | `system_time` | `Flow.run/2` begins |
| `[:phlox, :flow, :stop]` | `duration` | flow finishes |
| `[:phlox, :node, :start]` | `system_time` | before `prep/2` |
| `[:phlox, :node, :stop]` | `duration` | after `post/4` returns |
| `[:phlox, :node, :exception]` | `duration` | node raises after all retries |

All events include `flow_id`, `node_id`, and `module` in metadata.

### Attaching a handler

```elixir
:telemetry.attach_many(
  "my-app-phlox-logger",
  [
    [:phlox, :flow, :start],
    [:phlox, :flow, :stop],
    [:phlox, :node, :start],
    [:phlox, :node, :stop],
    [:phlox, :node, :exception]
  ],
  &MyApp.PhloxLogger.handle_event/4,
  nil
)

defmodule MyApp.PhloxLogger do
  require Logger

  def handle_event([:phlox, :node, :stop], %{duration: dur}, %{node_id: id}, _) do
    ms = System.convert_time_unit(dur, :native, :millisecond)
    Logger.debug("Node :#{id} completed in #{ms}ms")
  end

  def handle_event([:phlox, :node, :exception], _, %{node_id: id, reason: r}, _) do
    Logger.error("Node :#{id} failed: #{inspect(r)}")
  end

  def handle_event(_, _, _, _), do: :ok
end
```

### Stable flow IDs

By default, Phlox generates a unique `make_ref()` per run. Supply your own for
log correlation:

```elixir
Phlox.run(flow, %{
  phlox_flow_id: "ingest-job-" <> Integer.to_string(job_id),
  url: "..."
})
```

---

## Graph Validation

`Graph.to_flow/1` validates before you run anything, returning a list of human-readable
errors instead of a cryptic runtime crash:

```elixir
case Graph.to_flow(builder) do
  {:ok, flow} ->
    Phlox.run(flow, shared)

  {:error, reasons} ->
    Enum.each(reasons, &IO.puts/1)
end
```

Caught at build time:
- No start node set
- Start node not in the graph
- Successor references to nodes that don't exist
- Overwritten connections (warning, not error)

Use `to_flow!` to raise immediately on invalid config — useful in `Application.start/2`:

```elixir
@flow Graph.new()
      |> Graph.add_node(:fetch, FetchNode, %{})
      |> Graph.start_at(:fetch)
      |> Graph.to_flow!()   # raises at compile time if graph is invalid
```

---

## Design Patterns

### Simple Pipeline

A linear sequence of transformations. Each node does one thing.

```
[Fetch] → [Clean] → [Embed] → [Store]
```

```elixir
flow =
  Graph.new()
  |> Graph.add_node(:fetch, FetchNode, %{source: :web},   max_retries: 3)
  |> Graph.add_node(:clean, CleanNode, %{strip_html: true})
  |> Graph.add_node(:embed, EmbedNode, %{model: "ada-002"})
  |> Graph.add_node(:store, StoreNode, %{table: "docs"})
  |> Graph.connect(:fetch, :clean)
  |> Graph.connect(:clean, :embed)
  |> Graph.connect(:embed, :store)
  |> Graph.start_at(:fetch)
  |> Graph.to_flow!()
```

---

### Agent Loop

A self-directing loop: the LLM decides whether to continue or stop.

```
[Think] → [Act] → [Observe] ─"continue"→ [Think]
                            ─"done"──────▶ [Finish]
```

```elixir
defmodule MyAgent.ThinkNode do
  use Phlox.Node

  def prep(shared, _params) do
    %{
      goal:    shared.goal,
      history: Map.get(shared, :history, [])
    }
  end

  def exec(%{goal: goal, history: history}, params) do
    prompt = build_prompt(goal, history)
    MyLLM.call(prompt, params)
  end

  def post(shared, _prep, %{"action" => action, "done" => true}, _params) do
    {"done", Map.put(shared, :final_answer, action)}
  end

  def post(shared, _prep, %{"action" => action}, _params) do
    history = Map.get(shared, :history, [])
    new_shared = Map.put(shared, :next_action, action)
                 |> Map.put(:history, history ++ [action])
    {"continue", new_shared}
  end

  defp build_prompt(goal, history) do
    # ... build your ReAct-style prompt here
  end
end

defmodule MyAgent.ActNode do
  use Phlox.Node

  def prep(shared, _params), do: Map.fetch!(shared, :next_action)

  def exec(action, _params) do
    MyApp.Tools.execute(action)
  end

  def post(shared, _prep, result, _params) do
    {:default, Map.put(shared, :last_observation, result)}
  end
end

flow =
  Graph.new()
  |> Graph.add_node(:think,  MyAgent.ThinkNode,  %{model: "claude-3-5-sonnet"}, max_retries: 2)
  |> Graph.add_node(:act,    MyAgent.ActNode,    %{})
  |> Graph.add_node(:finish, MyAgent.FinishNode, %{})
  |> Graph.connect(:think, :act,    action: "continue")
  |> Graph.connect(:think, :finish, action: "done")
  |> Graph.connect(:act,   :think)    # loop back to think after acting
  |> Graph.start_at(:think)
  |> Graph.to_flow!()

{:ok, result} = Phlox.run(flow, %{goal: "Find the capital of the country with the most UNESCO sites"})
IO.puts(result.final_answer)
```

---

### RAG (Retrieval-Augmented Generation)

```
[Embed Query] → [Search Index] → [Rerank] → [Generate] → [Return]
```

```elixir
defmodule MyApp.EmbedQueryNode do
  use Phlox.Node
  def prep(shared, _p), do: shared.question
  def exec(question, _p), do: MyEmbedder.embed(question)
  def post(shared, _p, embedding, _p2), do: {:default, Map.put(shared, :query_embedding, embedding)}
end

defmodule MyApp.SearchNode do
  use Phlox.Node
  def prep(shared, _p), do: shared.query_embedding
  def exec(embedding, params) do
    MyVectorDB.search(embedding, top_k: params.top_k)
  end
  def post(shared, _p, chunks, _p2), do: {:default, Map.put(shared, :chunks, chunks)}
end

defmodule MyApp.GenerateNode do
  use Phlox.Node
  def prep(shared, _p), do: {shared.question, shared.chunks}
  def exec({question, chunks}, params) do
    context = Enum.map_join(chunks, "\n\n", & &1.text)
    MyLLM.call("Answer using context:\n#{context}\n\nQuestion: #{question}", params)
  end
  def post(shared, _p, answer, _p2), do: {:default, Map.put(shared, :answer, answer)}
end

flow =
  Graph.new()
  |> Graph.add_node(:embed,    MyApp.EmbedQueryNode, %{})
  |> Graph.add_node(:search,   MyApp.SearchNode,     %{top_k: 5})
  |> Graph.add_node(:generate, MyApp.GenerateNode,   %{model: "claude-3-5-sonnet"})
  |> Graph.connect(:embed, :search)
  |> Graph.connect(:search, :generate)
  |> Graph.start_at(:embed)
  |> Graph.to_flow!()

{:ok, result} = Phlox.run(flow, %{question: "What is event sourcing?"})
IO.puts(result.answer)
```

---

### Map-Reduce over a List

Fan out over a list in parallel, then reduce the results.

```elixir
defmodule MyApp.SummariseManyNode do
  use Phlox.BatchNode, parallel: true, max_concurrency: 5

  def prep(shared, _p), do: shared.documents
  def exec_one(doc, params), do: MyLLM.summarise(doc.text, params)
  def post(shared, _p, summaries, _p2) do
    {:default, Map.put(shared, :summaries, summaries)}
  end
end

defmodule MyApp.SynthesiseNode do
  use Phlox.Node
  def prep(shared, _p), do: shared.summaries
  def exec(summaries, params) do
    combined = Enum.join(summaries, "\n\n---\n\n")
    MyLLM.call("Synthesise these summaries into one:\n#{combined}", params)
  end
  def post(shared, _p, synthesis, _p2), do: {:default, Map.put(shared, :synthesis, synthesis)}
end

flow =
  Graph.new()
  |> Graph.add_node(:map,    MyApp.SummariseManyNode, %{style: :bullet})
  |> Graph.add_node(:reduce, MyApp.SynthesiseNode,    %{})
  |> Graph.connect(:map, :reduce)
  |> Graph.start_at(:map)
  |> Graph.to_flow!()

docs = [%{text: "..."}, %{text: "..."}, %{text: "..."}]
{:ok, result} = Phlox.run(flow, %{documents: docs})
IO.puts(result.synthesis)
```

---

### Multi-Agent Handoff

Each specialist agent is its own flow. A coordinator routes between them.

```elixir
defmodule MyApp.CoordinatorNode do
  use Phlox.Node

  def prep(shared, _p), do: shared.task

  def exec(task, _p) do
    MyLLM.classify_task(task)   # returns :research | :write | :code
  end

  def post(shared, _p, :research, _p2), do: {"research", shared}
  def post(shared, _p, :write,    _p2), do: {"write",    shared}
  def post(shared, _p, :code,     _p2), do: {"code",     shared}
end

# Each specialist is a sub-flow wrapped in a single delegation node
defmodule MyApp.ResearchDelegateNode do
  use Phlox.Node

  def exec(_prep, _p) do
    # Run the research sub-flow inline
    research_flow = MyApp.Flows.research_flow()
    {:ok, result} = Phlox.run(research_flow, %{})
    result
  end

  def post(_old_shared, _prep, result, _p) do
    {:default, result}    # the sub-flow's final shared becomes our shared
  end
end

coordinator_flow =
  Graph.new()
  |> Graph.add_node(:coord,    MyApp.CoordinatorNode,      %{})
  |> Graph.add_node(:research, MyApp.ResearchDelegateNode, %{})
  |> Graph.add_node(:write,    MyApp.WriteDelegateNode,    %{})
  |> Graph.add_node(:code,     MyApp.CodeDelegateNode,     %{})
  |> Graph.connect(:coord, :research, action: "research")
  |> Graph.connect(:coord, :write,    action: "write")
  |> Graph.connect(:coord, :code,     action: "code")
  |> Graph.start_at(:coord)
  |> Graph.to_flow!()
```

---

## Testing Your Nodes

Because `exec/2` has no access to shared state, nodes are trivially testable in isolation.

```elixir
defmodule MyApp.TranslateNodeTest do
  use ExUnit.Case, async: true

  alias MyApp.TranslateNode

  # Test exec directly — no graph, no flow, no shared state
  test "translates text to target language" do
    result = TranslateNode.exec(%{text: "hello", language: "fr"}, %{})
    assert result == {:ok, "bonjour"}
  end

  test "returns error for unsupported language" do
    result = TranslateNode.exec(%{text: "hello", language: "xx"}, %{})
    assert match?({:error, _}, result)
  end

  # Test post routing logic
  test "routes to :default on success" do
    shared = %{some: :state}
    {action, new_shared} = TranslateNode.post(shared, nil, {:ok, "bonjour"}, %{})
    assert action == :default
    assert new_shared.translation == "bonjour"
  end

  test "routes to 'error' on failure" do
    shared = %{}
    {action, new_shared} = TranslateNode.post(shared, nil, {:error, "unsupported"}, %{})
    assert action == "error"
    assert new_shared.error == "unsupported"
  end
end
```

For integration tests across multiple nodes, build a real flow with test-friendly nodes:

```elixir
defmodule MyApp.PipelineIntegrationTest do
  use ExUnit.Case, async: true

  defmodule StubFetchNode do
    use Phlox.Node
    def exec(_url, _p), do: "mocked body content"
    def post(shared, _p, body, _p2), do: {:default, Map.put(shared, :body, body)}
  end

  test "pipeline stores word count" do
    flow =
      Phlox.Graph.new()
      |> Phlox.Graph.add_node(:fetch, StubFetchNode,         %{})
      |> Phlox.Graph.add_node(:count, MyApp.CountWordsNode,  %{})
      |> Phlox.Graph.connect(:fetch, :count)
      |> Phlox.Graph.start_at(:fetch)
      |> Phlox.Graph.to_flow!()

    {:ok, result} = Phlox.run(flow, %{url: "http://stub"})
    assert result.word_count == 3
  end
end
```

---

## V2 Roadmap

These features were deliberately deferred from V1 to keep the core clean.
Each is designed to be purely additive — no breaking changes to existing node modules.

### Fan-out Mid-Flow
Allow a single node to emit a list and have the flow process each element
through a sub-graph, then merge results. Currently `BatchFlow` only fans out
at the top level. Mid-flow fan-out enables pipelines like:

```
[Fetch] → [Split into chunks] ──fan-out──▶ [Embed] ──merge──▶ [Store all]
```

### `Phlox.FlowServer` LiveView Integration
A `Phlox.LiveDashboard` component that connects to a `FlowServer` via PubSub
and shows a real-time node-by-node visualization of the running flow — which
node is active, current `shared` contents, duration per node.

### Persistent Flow State
A `Phlox.PersistentFlow` that checkpoints `shared` to Ecto after each node,
enabling flows to survive application restarts. Long-running agent loops
(document ingestion pipelines, multi-day research tasks) become resumable.

### `Phlox.Supervisor` Strategy Options
Expose the `DynamicSupervisor` restart intensity and period options through
`FlowSupervisor` configuration, making it easier to tune behaviour for
high-churn flow workloads.

### Macro DSL (optional)
An optional `Phlox.DSL` module providing a `flow do ... end` macro for
declarative graph wiring — for teams that prefer it over the builder API:

```elixir
use Phlox.DSL

flow MyApp.IngestFlow do
  start_at :fetch

  node :fetch,  MyApp.FetchNode,  %{}, max_retries: 3
  node :parse,  MyApp.ParseNode,  %{}
  node :store,  MyApp.StoreNode,  %{}
  node :error,  MyApp.ErrorNode,  %{}

  :fetch --> :parse
  :fetch --> :error,  on: "error"
  :parse --> :store
  :parse --> :error,  on: "error"
end
```

### Typed Shared State
An optional integration with `Ecto.Changeset` or `Norm` to declare a schema
for `shared`, validating it at each node boundary. Surfaces data contract
violations early — before an unexpected `nil` causes a cryptic crash three
nodes later.

---

## Attribution

Phlox is a port of **[PocketFlow](https://github.com/The-Pocket/PocketFlow)**
by [The Pocket](https://github.com/The-Pocket), originally written in Python.
PocketFlow's three-phase node lifecycle, graph wiring model, and batch flow
pattern are the direct inspiration for this library.

The Elixir design — explicit data threading, OTP supervision, behaviour-based
nodes, `FlowServer`/`FlowSupervisor`, and telemetry — is Phlox's own contribution.

---

## License

MIT
