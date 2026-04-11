# Changelog

All notable changes to Phlox are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Phlox adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.5.1] — 2026-04-11

### Fixed

- **Optional deps compilation bug** — LLM adapters, `Phlox.Adapter.Datastar`,
  `Phlox.Typed` (Gladius), and `Phlox.Adapter.Datastar.Plug` were never
  compiled when Phlox was used as a Hex dependency because their
  `Code.ensure_loaded?` guards ran before the consumer's deps were on the
  code path. Added `optional: true` declarations for `:req`, `:plug`,
  `:datastar_ex`, and `:gladius` so Mix compiles them before Phlox when
  present.

### Changed

- **README rewrite** — comprehensive documentation covering all modules,
  middleware vs. interceptors architecture, checkpointing/resume/rewind,
  LLM adapter swapping, Simplect/Complect token compression, Monitor,
  adapters, and the spinner. Full module map for AI agent consumption.
- Added `.formatter.exs` to Hex package files.
- Added `phlox-mark.png` logo to README header.

---

## [0.5.0] — 2026-04-11

### Added

- **Phlox spinner** — branded three-ring loading indicator shipped as
  standalone CSS (`priv/static/phlox-spinner.css`). Two states: idle (logo
  mark) and spinning (petals in motion). Collapse-and-bloom transition when
  toggling from active to idle. Four CSS custom properties for full
  theme control.
- **`Phlox.Component`** — Phoenix function component (`spinner/1`) with
  `:spinning`, `:size`, and `:class` attributes. Includes `role="status"`
  and dynamic `aria-label` for accessibility.
- **Favicon** — `priv/static/favicon.ico` (16/32/48px) and
  `priv/static/phlox-mark.png` derived from the spinner's idle state.
- **Datastar integration docs** — `data-class:spinning` binding examples
  for non-Phoenix consumers.
- Optional deps declared: `phoenix_live_view ~> 1.0` (for `Phlox.Component`)
  and `ecto_sql ~> 3.10` (for `Phlox.Checkpoint.Ecto`).

### Changed

- Hex package `files` list now includes `priv/static/` assets.
- `groups_for_modules` in ex_doc config updated to include UI and Adapter
  groups.

---

## [0.4.0] — 2026-04-05

### Added

- **`Phlox.Middleware`** — composable hook behaviour around the node lifecycle.
  Onion model: `before_node` fires in list order, `after_node` in reverse.
  Supports `{:cont, shared, action}` and `{:halt, reason}` returns.
- **`Phlox.Pipeline`** — middleware-aware orchestrator. Drop-in alternative
  to `Phlox.Runner` when you need hooks. Accepts `middlewares:`, `run_id:`,
  and `metadata:` options.
- **`Phlox.HaltedError`** — structured error raised when a middleware halts,
  carrying the module name and phase for diagnostics.
- **`Phlox.Checkpoint`** — behaviour for persistent flow state
  (`save/load/load_at/delete/list`).
- **`Phlox.Checkpoint.Memory`** — in-memory (Agent-backed) adapter for
  development and testing.
- **`Phlox.Checkpoint.Ecto`** — append-only event log adapter. Stores
  `node_completed`/`flow_completed`/`flow_errored` events with full
  `shared` snapshots.
- **`Phlox.Middleware.Checkpoint`** — wires the checkpoint behaviour into
  the middleware pipeline. Automatic save after every node.
- **`Phlox.resume/2` and `Phlox.rewind/2`** — resume from the latest
  checkpoint or rewind to a specific node in the event log.
- **`mix phlox.gen.migration`** — generates the `phlox_flow_events` Ecto
  migration.
- **`FlowServer` middleware routing** — `:middlewares` and `:resume`
  options accepted by `FlowServer.start_link/1`.

### Changed

- `Phlox.Runner` remains untouched — zero-dependency, zero-middleware
  baseline. `Pipeline` is the composition-aware alternative.

---

## [0.3.0] — 2026-04-04

### Added

- **`Phlox.FlowServer`** — GenServer wrapping flow execution with
  async start, status queries, and cancellation.
- **`Phlox.FlowSupervisor`** — DynamicSupervisor for concurrent flow
  instances with configurable limits.
- **`Phlox.Telemetry`** — `:telemetry` events for flow start, node
  start/stop, flow complete/error. Spans and measurements included.
- **`Phlox.BatchNode`** and **`Phlox.BatchFlow`** — parallel execution
  of node lifecycles over batched inputs.
- **`Phlox.Retry`** — configurable retry with exponential backoff and
  jitter. Per-node retry options via `retry_opts` in node params.

---

## [0.2.0] — 2026-04-03

### Added

- **`Phlox.Graph`** — compile-time graph builder with validation (missing
  start node, unknown successors, overwritten action warnings).
- **`Phlox.Flow`** — struct holding graph + start_id + metadata.
- **`Phlox.Runner`** — pure recursive orchestration loop. No GenServer,
  no side effects beyond calling node callbacks.
- **`Phlox.Node`** — behaviour defining `prep/2`, `exec/2`, `post/4`.

---

## [0.1.0] — 2026-04-02

### Added

- Initial port of [PocketFlow](https://github.com/The-Pocket/PocketFlow)
  to Elixir. Core abstractions: Node behaviour, Graph builder, Runner,
  Flow struct. 217 tests passing.

---

[0.5.1]: https://github.com/Xs-and-10s/phlox/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Xs-and-10s/phlox/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Xs-and-10s/phlox/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Xs-and-10s/phlox/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Xs-and-10s/phlox/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Xs-and-10s/phlox/releases/tag/v0.1.0
