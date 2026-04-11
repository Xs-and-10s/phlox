# Phlox

[![Hex.pm](https://img.shields.io/hexpm/v/phlox.svg)](https://hex.pm/packages/phlox)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/phlox)
[![License](https://img.shields.io/hexpm/l/phlox.svg)](LICENSE)

Graph-based orchestration engine for AI agent pipelines in Elixir.

Phlox gives you a three-phase node lifecycle (**prep → exec → post**),
declarative graph wiring, composable middleware, persistent checkpointing
with resume and rewind, batch flows, OTP supervision, and adapters for
Phoenix LiveView and Datastar SSE — all in a library small enough to read
in an afternoon.

Phlox is an Elixir adaptation of
[PocketFlow](https://github.com/The-Pocket/PocketFlow) by
[The Pocket](https://github.com/The-Pocket), redesigned around explicit
data threading, behaviours, and OTP.

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

Phlox's core has zero required dependencies beyond `:telemetry`. Adapters
and checkpoint stores pull in their own deps only when you use them:

| Feature | Dependency | When needed |
|---|---|---|
| `Phlox.Component` (spinner) | `phoenix_live_view ~> 1.0` | Phoenix apps using the HEEx spinner component |
| `Phlox.Checkpoint.Ecto` | `ecto_sql ~> 3.10` | Persistent checkpointing via Ecto |

---

## Quick start

Define nodes by implementing the `Phlox.Node` behaviour:

```elixir
defmodule MyApp.FetchNode do
  @behaviour Phlox.Node

  @impl true
  def prep(shared, _params), do: shared[:url]

  @impl true
  def exec(url, _params), do: HTTPClient.get!(url).body

  @impl true
  def post(shared, _url, body, _params) do
    {:next, Map.put(shared, :body, body)}
  end
end

defmodule MyApp.ParseNode do
  @behaviour Phlox.Node

  @impl true
  def prep(shared, _params), do: shared[:body]

  @impl true
  def exec(body, _params), do: Jason.decode!(body)

  @impl true
  def post(shared, _body, parsed, _params) do
    {:done, Map.put(shared, :parsed, parsed)}
  end
end
```

Wire them into a flow:

```elixir
flow =
  Phlox.Graph.new()
  |> Phlox.Graph.add_node(:fetch, MyApp.FetchNode)
  |> Phlox.Graph.add_node(:parse, MyApp.ParseNode)
  |> Phlox.Graph.add_edge(:fetch, :next, :parse)
  |> Phlox.Graph.build!(:fetch)

shared = %{url: "https://api.example.com/data"}
result = Phlox.Runner.run(flow, shared)
# => %{url: "...", body: "...", parsed: %{...}}
```

---

## Core concepts

### The three-phase lifecycle

Every node implements three callbacks:

1. **`prep/2`** — extract what you need from `shared` (the flowing state map)
2. **`exec/2`** — do the work (LLM call, HTTP request, computation). This is
   the only phase that retries on failure.
3. **`post/4`** — merge results back into `shared` and return an action atom
   that determines the next node

This separation keeps side effects in `exec` and routing logic in `post`.
`shared` is an explicit data thread — no hidden process state, no magic
assigns.

### Graph wiring

```elixir
Phlox.Graph.new()
|> Phlox.Graph.add_node(:classify, ClassifyNode)
|> Phlox.Graph.add_node(:summarize, SummarizeNode)
|> Phlox.Graph.add_node(:translate, TranslateNode)
|> Phlox.Graph.add_edge(:classify, :text, :summarize)
|> Phlox.Graph.add_edge(:classify, :foreign, :translate)
|> Phlox.Graph.build!(:classify)
```

`build!/2` validates at compile time: missing start node, unknown successor
references, and overwritten action edges all raise or warn.

### Retry

Per-node retry with exponential backoff and jitter:

```elixir
Phlox.Graph.add_node(:llm_call, MyLLMNode,
  retry_opts: [max_attempts: 3, base_delay: 1_000, max_delay: 10_000]
)
```

Only `exec/2` retries. `prep` and `post` are deterministic — if they fail,
the bug is in your code, not in a flaky external service.

### Batch flows

`Phlox.BatchNode` and `Phlox.BatchFlow` execute the node lifecycle in
parallel across batched inputs. Same three-phase contract, automatic
fan-out/fan-in.

---

## Middleware

`Phlox.Pipeline` is a middleware-aware orchestrator. It wraps each node's
lifecycle in an onion of hooks:

```elixir
Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
  run_id: "ingest-run-42",
  middlewares: [
    MyApp.Middleware.CostTracker,
    Phlox.Middleware.Checkpoint
  ],
  metadata: %{
    checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}
  }
)
```

`before_node` fires in list order, `after_node` in reverse (first in, last
out). Any middleware can halt the flow with `{:halt, reason}`, which raises
`Phlox.HaltedError` with the module name and phase for diagnostics.

`Phlox.Runner` remains the zero-dependency, zero-middleware baseline. Use it
when you don't need hooks.

---

## Checkpointing, resume, and rewind

`Phlox.Checkpoint.Ecto` writes an append-only event log — one row per node
completion. This gives you:

- **Resume** from the latest checkpoint after a crash
- **Rewind** to any prior node (e.g., re-execute after detecting a
  hallucination three nodes downstream)
- Full audit trail of every node transition

```elixir
# Generate the migration
mix phlox.gen.migration

# Resume from latest checkpoint
{:ok, checkpoint} = Phlox.Checkpoint.Ecto.load("run-42", repo: MyApp.Repo)
Phlox.resume(checkpoint, flow: my_flow, middlewares: [...])

# Rewind to a specific node
{:ok, checkpoint} = Phlox.Checkpoint.Ecto.load_at("run-42",
  node_id: :chunk,
  repo: MyApp.Repo
)
Phlox.resume(checkpoint, flow: my_flow, middlewares: [...])
```

For development and testing, `Phlox.Checkpoint.Memory` provides an
Agent-backed in-memory adapter with the same interface.

---

## OTP integration

### FlowServer

`Phlox.FlowServer` is a GenServer wrapping flow execution with async start,
status queries, cancellation, and optional middleware/resume support:

```elixir
{:ok, pid} = Phlox.FlowServer.start_link(
  flow: my_flow,
  shared: %{url: "..."},
  middlewares: [Phlox.Middleware.Checkpoint]
)

Phlox.FlowServer.status(pid)
# => :running | {:done, result} | {:error, reason}
```

### FlowSupervisor

`Phlox.FlowSupervisor` is a DynamicSupervisor for running concurrent flow
instances with configurable limits.

---

## Adapters

### Phoenix LiveView

`Phlox.Adapter.Phoenix` streams flow progress into LiveView assigns. Use
the built-in `FlowMonitor` component or build your own with telemetry events.

### Datastar SSE

`Phlox.Adapter.Datastar` provides a Plug that streams SSE events compatible
with Datastar's `datastar-patch-signals` and `datastar-patch-elements` event
types. Bind your UI to flow status signals:

```html
<span class="phlox-spinner"
      data-class:spinning="$flow_status === 'streaming'">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>
```

---

## The Phlox spinner

Phlox ships a branded three-ring loading indicator. Three concentric rings
spin at different speeds and directions, evoking petals in motion. When the
flow completes, the rings collapse to a point, hold briefly, then bloom back
to their idle positions — a visual confirmation beat.

The idle state doubles as a logo mark. The favicon is derived from it.

### Phoenix

```elixir
# In your layout:
<link rel="stylesheet" href={~p"/deps/phlox/priv/static/phlox-spinner.css"}>

# In your LiveView or component:
<Phlox.Component.spinner spinning={@flow_running} />
<Phlox.Component.spinner spinning={@flow_running} size="48px" />
```

### Datastar / plain HTML

```html
<link rel="stylesheet" href="/path/to/phlox-spinner.css">

<!-- Idle -->
<span class="phlox-spinner">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>

<!-- Active -->
<span class="phlox-spinner spinning">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>

<!-- Datastar toggle -->
<span class="phlox-spinner"
      data-class:spinning="$flow_status === 'streaming'">
  <span class="phlox-ring phlox-ring-outer"></span>
  <span class="phlox-ring phlox-ring-middle"></span>
  <span class="phlox-ring phlox-ring-inner"></span>
</span>
```

### Collapse-and-bloom transition

To trigger the collapse-and-bloom when stopping (instead of a hard cut),
add the `collapsing` class after removing `spinning`:

```javascript
const spinner = document.querySelector('.phlox-spinner');
spinner.classList.remove('spinning');
spinner.classList.add('collapsing');
spinner.addEventListener('animationend', () => {
  spinner.classList.remove('collapsing');
}, { once: true });
```

The rings reset to their idle angles at the midpoint of the collapse while
invisible, so the bloom always reveals a clean idle state.

### Customization

Override CSS variables to match your brand:

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

## Telemetry events

Phlox emits `:telemetry` events at every lifecycle boundary:

| Event | Measurements | Metadata |
|---|---|---|
| `[:phlox, :flow, :start]` | `system_time` | `flow`, `shared`, `run_id` |
| `[:phlox, :node, :start]` | `system_time` | `node_id`, `node`, `shared` |
| `[:phlox, :node, :stop]` | `duration` | `node_id`, `action`, `shared` |
| `[:phlox, :flow, :stop]` | `duration` | `flow`, `shared`, `run_id` |
| `[:phlox, :flow, :exception]` | `duration` | `flow`, `kind`, `reason`, `stacktrace` |

Attach handlers with `:telemetry.attach/4` or use the built-in
`Phlox.Telemetry` module which provides a default logging handler.

---

## Attribution

Phlox is a port of **[PocketFlow](https://github.com/The-Pocket/PocketFlow)**
by [The Pocket](https://github.com/The-Pocket), originally written in Python.
PocketFlow's elegant three-phase node lifecycle, graph wiring model, and batch
flow pattern are the direct inspiration for this library. The Elixir design —
explicit data threading, OTP supervision, behaviour-based nodes, middleware,
checkpointing, and telemetry — is Phlox's own contribution.

---

## License

MIT
