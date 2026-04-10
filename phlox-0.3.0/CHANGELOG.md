# Changelog

All notable changes to this project are documented in this file.

## [0.3.0] — 2026-04-10

### Added

**Middleware system (V2.7a)**
- `Phlox.Middleware` behaviour with `before_node/2` and `after_node/3` callbacks
- `Phlox.Pipeline` orchestrator — wraps Runner with composable middleware stack
- Onion-model execution: before hooks fire in list order, after hooks fire in reverse
- `{:halt, reason}` support — any middleware can abort the flow
- `Phlox.HaltedError` exception with reason, node id, middleware module, and phase

**Persistent checkpoints (V2.7b–d)**
- `Phlox.Checkpoint` behaviour — append-only event log contract
- `Phlox.Checkpoint.Memory` — Agent-backed in-memory adapter for dev/test
- `Phlox.Checkpoint.Ecto` — Postgres adapter with unique `{run_id, sequence}` index
- `Phlox.Middleware.Checkpoint` — saves shared state after each node completes
- `mix phlox.gen.migration` — generates the `phlox_checkpoints` table migration

**Resume and rewind (V2.7e)**
- `Phlox.Resume.resume/2` — continue a flow from its latest checkpoint
- `Phlox.Resume.rewind/3` — reload a checkpoint by node id and re-execute downstream
- Resumed runs automatically include checkpoint middleware
- `:resumed_from` metadata injected into pipeline context for traceability

**FlowServer integration (V2.7g)**
- `Phlox.FlowServer` accepts `:middlewares`, `:run_id`, and `:metadata` options
- Step mode fires middleware hooks per step
- `:resume` option loads checkpoint during init, starts from the checkpointed node
- `state/1` snapshot includes `run_id`
- `reset/2` generates a fresh run_id

**Typed shared state (V2.8)**
- `Phlox.Typed` — `use` macro providing `input/1` and `output/1` spec declarations
- `Phlox.Middleware.Validate` — enforces specs at node boundaries
- Gladius integration: full spec algebra (schemas, transforms, coercions, defaults)
- Plain function fallback when Gladius is not a dependency
- Shaped values replace shared — specs actively participate in data flow

**Interceptors (V2.9)**
- `Phlox.Interceptor` behaviour with `before_exec/2` and `after_exec/2` callbacks
- `intercept` macro — declare interceptors directly on node modules
- Interceptors run inside the retry loop, wrapping each exec attempt
- `{:skip, value}` — short-circuit exec (cache hits, circuit breakers)
- `{:halt, reason}` — abort from the exec boundary
- Access boundary enforced: interceptors see prep_res/exec_res, not shared

**LLM provider abstraction**
- `Phlox.LLM` behaviour with `chat/2` callback
- `Phlox.LLM.Anthropic` — Claude API adapter
- `Phlox.LLM.Google` — Gemini AI Studio adapter (free tier: 1,500 req/day)
- `Phlox.LLM.Groq` — Groq inference adapter (free tier: 14,400 req/day)
- `Phlox.LLM.Ollama` — Local model adapter via Ollama
- All adapters guarded by `Code.ensure_loaded?(Req)` — zero-dep when Req is absent

**Examples**
- `Phlox.Examples.CodeReview` — multi-agent code review pipeline (security, logic, style, synthesizer)

### Changed

- `Phlox.Retry.run/2` now accepts an optional third argument `exec_fn` for interceptor wrapping (backward compatible — `nil` default calls `mod.exec/2` directly)
- `Phlox.Node.__using__` now imports `intercept` from `Phlox.Interceptor` and registers the `@phlox_interceptors` accumulating attribute

### Fixed

- `function_exported?/3` does not trigger module loading — `Pipeline` and `FlowServer` now use `Code.ensure_loaded?/1` before checking exports

## [0.2.0] — 2026-04-05

### Added

- `Phlox.FlowSupervisor` — DynamicSupervisor with configurable `max_restarts`/`max_seconds`
- `Phlox.DSL` — declarative `flow do ... end` macro for graph wiring
- `Phlox.FanOutNode` — mid-flow fan-out with sub-flow per item
- `Phlox.Monitor` — real-time flow tracking via ETS + telemetry
- `Phlox.Adapter.Phoenix` — LiveView mixin with `phlox_subscribe/2`
- `Phlox.Adapter.Datastar` — SSE streaming via Plug

## [0.1.0] — 2026-04-04

### Added

- `Phlox.Node` behaviour with prep → exec → post lifecycle
- `Phlox.BatchNode` — sequential and parallel batch processing
- `Phlox.BatchFlow` — full-flow fan-out with param overrides
- `Phlox.Graph` — builder API for wiring nodes into flows
- `Phlox.Flow` — `%Flow{}` struct with `run/2`
- `Phlox.Runner` — pure orchestration loop (zero OTP coupling)
- `Phlox.Retry` — configurable retry with `exec_fallback/3`
- `Phlox.FlowServer` — GenServer wrapper with run/step/state/reset
- `Phlox.Telemetry` — soft-dep telemetry emission
- Graph validation on `to_flow!/1` — catches missing start nodes, unknown successors
