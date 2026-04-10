# PXML Specification v2.6

**Plugin-Extension Markup Language**
Version: 0.2.6-draft
Status: Design phase — not yet implemented
Authors: Mark Manley, with design assistance from Claude (Anthropic)
Supersedes: PXML_SPEC_v2.5.md v0.2.5-draft

---

## 1. Purpose

PXML is a bulk-flow command language for describing AI agent pipelines. It exists in two modes that share one grammar:

- **Block mode** — a structured document describing agents, tool scoping, interceptors, lifecycle phases, and prompts. This is what an orchestration engine (Phlox) executes as chunks arrive through the buffer.
- **Inline mode** — sigil-annotated natural language with bookended commands that a human writes inside a free-text prompt. The AAA pipeline (Advocate → Analyst → Agent) compiles inline PXML into block mode for execution. The compilation is stored as an event-sourced aggregate.

PXML is designed to be:

- Bulk-flow — fixed-size chunks of complete elements flow through a buffer at a consumer-controlled rate
- Commandable — 76 bookended commands across 9 control axes give users prompt-time power over every aspect of the pipeline
- Readable by humans and parseable by LLMs without a formal parser
- Embeddable in free-text prompts as small annotated fragments
- Compilable into Phlox graph structs for execution
- Event-sourced — every mutation is an immutable event, projectable into any read model
- Framework-agnostic — Gladius validates PXML schemas whether the downstream consumer is Phoenix, Bandit, SpaceCowboy, or bare Plug


---

## 2. Design principles

1. **Sigils are the parse hints.** Every structured element in inline mode is prefixed with a sigil that an LLM can extract without a formal parser.

2. **Block mode is the compilation target.** Inline mode is lossy by design. Block mode captures the full execution plan including explicit defaults.

3. **Bulk flow, not batch, not streaming.** The parser produces fixed-size chunks of complete bookended elements into a buffer. The consumer (Phlox) pulls chunks at its own pace via demand-based backpressure. GenStage/Flow semantics.

4. **Capability scoping, not capability binding.** Tools are picked into and dropped from a mutable toolbelt. The prompt decides invocation; pick/drop decides possibility.

5. **The document is the scope.** Tool availability, interceptor configuration, and state typing are lexically scoped by document structure.

6. **Phlox is the runtime, PXML is the notation, Gladius is the contract.** None of the three depend on each other. Bridges connect them.

7. **The Interceptor is a specific Extension.** Extensions are persistent. Plugins are ephemeral. The Interceptor Extension manages plugin activation on individual nodes.

8. **Event-sourced persistence.** Compilations are aggregates. Every mutation is an immutable event. Read models are projections.

9. **The interceptor pipeline has a canonical order.** The Interceptor Extension owns the execution sequence. Nodes declare *what*, not *when*.

10. **Commands shape intent and process.** Data transformation belongs in interceptor plugins and Gladius specs. Commands control what to do, how to think, who does it, how to communicate, what to protect, how to verify, what to remember, and when to proceed.

11. **AAA is the compilation step.** The Advocate (SLM), Analyst (MLM), and Agent (LLM) are not a separate system — they are the pipeline that turns inline PXML into compiled block PXML and then executes it.


---

## 3. Architecture overview

### 3.1 Package topology

```
phlox              — graph execution engine (no PXML knowledge)
gladius            — validation/spec library (no Phlox knowledge)
phlox_gladius      — bridge: Interceptor Extension + Validate Plugin
pxml               — parser + compiler (depends on phlox, gladius, phlox_gladius)
pxml_store         — CQRS/ES persistence (depends on pxml, uses Commanded + Postgres)
sos                — SOS Coding: Observer Extension + Scenario store + Verdict system
```

Optional framework bridges:

```
gladius_phoenix    — Gladius integration for Phoenix
gladius_bandit     — Gladius integration for Bandit
gladius_plug       — Gladius integration for bare Plug
space_cowboy       — Datastar-native Elixir server with built-in Gladius + PXML
```

### 3.2 The AAA pipeline (Advocate → Analyst → Agent)

The inline→block compilation step is performed by three specialized models in sequence:

```
Human writes inline PXML
         │
         ▼
┌─────────────────────────────────────────┐
│  Advocate (SLM)                         │
│  Knows the user. Clarifies intent.      │
│  Processes: /prompt /merge /goal /me    │
│             /ask /tone /recall /pin    │
│             /prefer                     │
│  Output: clarified prompt, user context │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Analyst (MLM)                          │
│  Knows the domain. Applies precision.   │
│  Processes: /context /assume /agent     │
│             /validate /plan /include    │
│             /constraint /scope /ignore  │
│             /redact /sandbox /without   │
│             /extend /pick-tool etc.     │
│  Output: compiled PXML block document   │
└────────────────┬────────────────────────┘
                 │  InlineCompiled event stored
                 ▼
┌─────────────────────────────────────────┐
│  Agent (LLM)                            │
│  Knows the codebase. Executes.          │
│  Processes: /think /selftalk /critique  │
│             /implement /research etc.   │
│  Output: results + execution trace      │
└─────────────────────────────────────────┘
```

**Why Advocate first:** You can't apply domain precision (Analyst) to ambiguous intent. The Advocate clarifies what the human actually wants, then the Analyst maps that onto the domain with correct terminology, constraints, and scenarios.

**Model sizing:** The Advocate (SLM) does focused pattern matching on user communication. The Analyst (MLM) does domain reasoning and constraint inference. The Agent (LLM) needs full capability for codebase-level execution.

**Command routing:** Each AAA stage only processes commands targeted at it and passes the rest through. The Advocate never sees `/think`; the Analyst never sees `/me`.

### 3.3 The Extension / Plugin / Interceptor relationship

```
Extensions (persistent, cross-cutting)
├── Telemetry Extension
├── Audit Log Extension
├── Circuit Breaker Extension
├── Token Ledger Extension
├── Observer Extension (SOS)         ← runs in separate graph, sees everything
│   ├── Reads Specifications         (Gladius behavioral contracts)
│   ├── Reads Scenarios              (exogenous, agent-invisible)
│   ├── Watches codebase changes
│   └── Emits Verdicts               (reward/penalize)
└── Interceptor Extension            ← the distinguished one
    │
    │  manages plugin activation per-node
    │  owns the canonical execution pipeline
    │
    ├── Validate Plugin              (uses Gladius via phlox_gladius)
    ├── Retry Plugin
    ├── Fallback Model Plugin
    ├── Structured Output Plugin
    ├── Rate Limit Plugin
    ├── Redact Plugin
    ├── Cache Plugin
    └── Guard Plugin

Plugins (ephemeral, per-run, wrap entire traversal)
├── Dry Run
├── Debug Trace
├── Timeout Budget
├── Cost Ceiling
└── Seed Pin
```

### 3.4 Bulk flow model

```
Source (text)
    │
    ▼
┌─────────────────────────┐
│  Parser (nimble_parsec)  │
│  produces: complete      │
│  bookended elements      │
│  chunk size: 1 element   │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│  Buffer (GenStage)       │
│  max_demand: configurable│
│  min_demand: configurable│
│  backpressure: demand    │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│  Consumer (Phlox)        │
│  pulls elements on       │
│  demand, begins          │
│  execution as phases     │
│  arrive                  │
└─────────────────────────┘
```

Chunk boundaries: `<defaults>`, `<state>`, `<capability>`, `<prep>`, `<exec>`, `<post>`, `<with>` — each emitted as a complete AST node when its bookend closes.

### 3.5 Protocol architecture

PXML sits above two communication protocols that serve different layers of the stack:

```
┌─────────────────────────────────────────────────┐
│  PXML                                           │
│  Human intent → compiled pipeline → execution   │
│  76 commands across 9 control axes              │
├──────────────────────┬──────────────────────────┤
│  A2A (agent layer)   │  MCP (tool layer)        │
│                      │                          │
│  Agent ↔ Agent       │  Agent → Tool Server     │
│  Peer communication  │  Client-server invocation│
│  /message command    │  /pick-tool, /drop-tool   │
│  <capability> block  │  Tool scoping system     │
│  Discovery via       │  Tools exposed via        │
│   Agent Cards        │   MCP server manifests   │
│                      │                          │
│  Google + IBM (ACP)  │  Anthropic               │
│  Linux Foundation    │                          │
└──────────────────────┴──────────────────────────┘
```

**A2A** (Agent-to-Agent Protocol) is the unified agent communication standard. IBM's ACP (Agent Communication Protocol) merged into Google's A2A under the Linux Foundation in August 2025. ACP's strengths — REST-based communication, no SDK required, offline discovery via embedded metadata — were folded into the A2A standard. In PXML:

- `<capability>` declares what a namespace exposes (maps to A2A Agent Card)
- `/message` invokes another namespace's capabilities at runtime (maps to A2A Task)
- `%protocols = [A2A/1.0]` advertises protocol support
- Discovery uses glob patterns on `/message to = *` to find matching Agent Cards

**MCP** (Model Context Protocol) is the tool invocation standard. An LLM connects to MCP servers that expose tools, resources, and prompts. MCP is client-server, not peer-to-peer — the model is always the client. In PXML:

- `/pick-tool` and `/drop-tool` manage which MCP tools are available
- Tool scoping (deny-all, allow-some) provides security sandboxing
- A single general-purpose MCP server (e.g., `mcp:script_runner`) can accept and execute scripts, avoiding the context bloat of many specialized tool schemas

**The key distinction:** MCP is about *what tools an agent can use*. A2A is about *what agents can say to each other*. PXML commands orchestrate both: `/pick-tool` and `/drop-tool` manage the MCP layer, `/message` and `<capability>` manage the A2A layer.


---

## 4. Sigil table

| Sigil | Name | Meaning | Example |
|-------|------|---------|---------|
| `%` | Attribute | Metadata key on an element | `%name = fetch_context.` |
| `^` | Spec ref | Gladius registry lookup | `^findings_list` |
| `@` | Mention | Agent or human reference | `@security_scan` |
| `#` | Tag | Label, category, or redaction target | `#env_vars` |
| `/` | Command | Bookended command (see section 7) | `/critique ... critique/` |
| `.` | Terminator | Ends a value | `%timeout = 10s.` |
| `=` | Assignment | Binds a value to an attribute | `%model = claude-opus.` |
| `:` | Type annotation | Declares a type constraint | `%pr_diff : ^diff_schema.` |
| `~~` | Comment | Bookended comment | `~~ this is a note ~~` |
| `[,]` | List | Ordered collection | `[#env_vars, #api_keys]` |
| `'...'` | Literal | Escapes sigil parsing | `'sending:to:LLM'` |
| `` ` `` | Inline code | Code reference (no sigil parsing) | `` `GenServer.call/3` `` |
| ```` ``` ```` | Fenced code | Multi-line code block | ```` ```elixir ... ``` ```` |

### Sigil precedence in inline mode

1. `/command` — imperative, highest priority
2. `@mention` — agent/human references
3. `^spec` — type/schema references
4. `#tag` — labels and categories
5. `%attribute` — contextual metadata

### Code in PXML (backtick support)

Backtick-delimited content is opaque — no sigil parsing occurs inside:

**Inline code:** `` `@module_attribute` `` — the `@` is literal, not an agent mention.

**Fenced code blocks:**

````
```elixir
defmodule MyApp.Worker do
  use GenServer
  # This % and @ are code, not PXML
end
```
````

The language hint after the opening fence (`elixir`, `typescript`, etc.) is optional. It enables syntax highlighting in Tree-sitter-aware editors and is preserved in the AST for downstream consumers.

**Inside `<prompt= =prompt>` blocks:** Backticks are literal since freetext mode already suppresses structural parsing. However, backtick content is still marked as code in the AST for rendering purposes.

**Parser rule:** Backtick-delimited content is treated identically to single-quoted literals (`'...'`) for parsing purposes — the content is opaque. The distinction is semantic: backticks mean "this is code," single quotes mean "this contains sigil-like characters that aren't sigils."


---

## 5. Syntax

### 5.1 Elements (bookended)

```
<element-name ... element-name>
```

Symmetric bookend closing. The word at both ends is the same.

### 5.2 Attributes

```
%name = fetch_context.
%retry : int(gte: 0) = 3.
%on-failure : [halt, warn, skip, fallback] = halt.
```

Prefixed with `%`, terminated with `.`. Optional `:` type annotation between name and `=`.

### 5.3 Values

- **Atoms:** `halt.` `true.` `json.`
- **Numbers:** `3.` `0.50.` — parser is greedy, reads longest valid numeric before final `.`
- **Durations:** `10s.` `1h.` `120s.` `500ms.` `1/min.`
- **Currency:** `$0.50.`
- **Strings:** Unquoted when unambiguous. Single-quoted `'like:this'` for sigil-active characters.
- **Lists:** `[a, b, c].`
- **Spec refs:** `^schema_name.`
- **Agent refs:** `[@agent_a, @agent_b].`
- **Tag refs:** `[#env_vars, #api_keys].`
- **Globs:** `github:*.`
- **Code:** `` `GenServer.call/3` `` — inline code literal
- **Compilation refs:** `pxml:a1b2c3d4` — short form (first 8 chars) or full UUID

### 5.4 Freetext blocks

```
<prompt=
  Review this diff. Cite line numbers from %pr_diff.
=prompt>
```

The `=` mode switch. `%name` interpolates state variables. All other sigils are literal.

### 5.5 Comments

```
~~ this is a comment ~~
```

### 5.6 Namespaces

```
<pxml %ns = PXML:org:pxml:brain-trust.
```


---

## 6. Block mode elements

### 6.1 Root: `<pxml>`

| Attribute | Required | Description |
|-----------|----------|-------------|
| `%ns` | Yes | Reverse-domain namespace |
| `%version` | Yes | PXML spec version |
| `%context` | No | URL to external schema/documentation |
| `%compiled_from` | No | UUID of the inline source |
| `%compiled_at` | No | ISO 8601 compilation timestamp |
| `%compilation_id` | No | UUID of the compilation aggregate |
| `%parent_id` | No | UUID of the parent compilation (for `/extend` and `/without` chains) |
| `%revision` | No | Revision number within a parent chain |

Children: `<defaults>`, `<state>`, `<prep>`, `<exec>`, `<post>`, `<with>`, `<capability>`, `<sos>`

### 6.2 Defaults: `<defaults>`

Explicit values for everything inline mode leaves implicit:

```
<defaults
  %model = claude-sonnet.
  %timeout : duration = 30s.
  %on-failure : [halt, warn, skip, fallback] = warn.
  %retry : int(gte: 0) = 2.
  %structured_output : [json, xml, custom, none] = none.
  %output_schema = none.
  %fallback_model = none.
  %cache : [duration, off] = off.
  %rate_limit = 10/min.
  %redact = [].
  %guard : [guard_name, none] = none.
  %audit_log : bool = false.
  %tool-inheritance : [inherit, empty] = inherit.
defaults>
```

### 6.3 State: `<state>`

```
<state
  %pr_diff   : ^diff_schema.
  %findings  : ^findings_list.
  %review    : ^review_output.
state>
```

### 6.4 Lifecycle phases: `<prep>`, `<exec>`, `<post>`

PXML pipeline phases share names with PocketFlow's per-node lifecycle methods. This is intentional — the concepts operate at two levels:

**PocketFlow level (per-node, internal to Phlox):** Every Phlox node internally follows PocketFlow's three-method lifecycle:
- `prep(shared)` — Read and preprocess data from shared store. No side effects.
- `exec(prep_res)` — Pure compute: LLM calls, API calls, tool invocations. Must NOT access shared store. Retryable. Must be idempotent if retries are enabled.
- `post(shared, prep_res, exec_res)` — Write results to shared store. Decide the next action (routing). Return an action string.

This separation of concerns is a PocketFlow invariant that Phlox must honor: data storage (prep/post) and data processing (exec) are operated separately.

**PXML level (pipeline phases, groups of agents):** PXML lifts the same three names to organize the pipeline into phases, each containing one or more agents:
- **`<prep>`** — Preparation phase. Agents that fetch context, establish tool availability, validate preconditions. Runs once before execution. Analogous to PocketFlow's `prep()` at the pipeline scale: reading and preprocessing before the main work.
- **`<exec>`** — Execution phase. The core agent graph. May contain `<plan>` blocks for parallel/sequential orchestration. Analogous to PocketFlow's `exec()` at the pipeline scale: the main compute work.
- **`<post>`** — Post-processing phase. Agents that publish results, clean up resources, fire notifications. Runs once after execution. Analogous to PocketFlow's `post()` at the pipeline scale: writing results and deciding what's next.

**Bulk flow behavior:** Each phase is emitted as a complete chunk when its bookend closes. Phlox can begin executing `<prep>` as soon as it arrives. Within each phase, individual agents still follow PocketFlow's per-node prep→exec→post internally.

### 6.5 Agent: `<agent>`

| Attribute | Required | Default source | Description |
|-----------|----------|----------------|-------------|
| `%name` | Yes | — | Unique identifier |
| `%model` | No | `<defaults>` | LLM model |
| `%depends_on` | No | `[]` | List of `@agent` refs |
| `%timeout` | No | `<defaults>` | Per-agent timeout |
| `%on-failure` | No | `<defaults>` | Failure policy |

Children: `<pick-tool>`, `<drop-tool>`, `<intercept>`, `<prompt=>`, `<system=>`

**Fully explicit compiled agent:**

```
<agent %name = security_scan.
  %model = claude-opus.
  %depends_on = [].
  %timeout = 30s.
  %on-failure = warn.
  <intercept
    %validate_in = none.
    %validate_out = ^findings_list.
    %retry = 3.
    %structured_output = json.
    %output_schema = json_schema.
    %fallback_model = none.
    %cache = off.
    %rate_limit = 10/min.
    %redact = [].
    %guard = block_if_hallucinated_cve.
    %audit_log = false.
  intercept>
  <prompt=
    Review this diff for security vulnerabilities.
    Focus on: injection, auth bypass, secret leakage.
    Cite exact line numbers from %pr_diff.
  =prompt>
agent>
```

**Using `<system=>` and `<prompt=>` together:**

A single agent can have both a system prompt (stable persona/instructions) and a task prompt (per-run content). `<system=>` maps to the `system` message role in the LLM API; `<prompt=>` maps to the `user` message role.

```
<agent %name = security_scan.
  %model = claude-opus.

  <system=
    You are a senior security engineer with 15 years of experience
    in application security. You specialize in OWASP Top 10
    vulnerabilities and have deep expertise in Elixir/Phoenix
    security patterns. You are thorough but constructive — you
    flag real issues, not style preferences. When you cite a
    vulnerability, include the CWE number.
  =system>

  <prompt=
    Review this diff for security vulnerabilities.
    Focus on: injection, auth bypass, secret leakage.
    Cite exact line numbers from %pr_diff.
    The codebase uses Commanded for event sourcing —
    pay special attention to command validation.
  =prompt>

  <intercept
    %validate_out = ^findings_list.
    %retry = 3.
    %structured_output = json.
  intercept>
agent>
```

The `<system=>` is stable across invocations — it defines who the agent *is*. The `<prompt=>` changes per run — it defines what the agent *does this time*. When compiling from inline mode, the Analyst generates `<system=>` from `/as` commands and user context, and `<prompt=>` from `/task` and freetext content.

### 6.6 Plan: `<plan>`

| Attribute | Required | Description |
|-----------|----------|-------------|
| `%orchestration` | Yes | `parallel`, `sequential`, `race`, `round-robin` |

### 6.7 Tool scoping: `<pick-tool>`, `<drop-tool>`

**`<pick-tool>`:**

| Attribute | Required | Default source | Description |
|-----------|----------|----------------|-------------|
| `%name` | Yes | — | Tool identifier or glob |
| `%on-failure` | No | `<defaults>` | `halt`, `warn`, `skip`, `fallback` |

**`<drop-tool>`:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `%name` | Yes | Tool identifier or glob |

**Scoping rules:**

1. Inheritance direction set by `%tool-inheritance` in `<defaults>`.
2. Glob drops clear entire namespaces.
3. Pick after glob drop = whitelist (deny-all, allow-some).
4. Post-phase pick/drop ordering = LIFO lifecycle stack.

### 6.8 Intercept: `<intercept>`

Declares per-node plugin activation via the Interceptor Extension.

**The canonical interceptor pipeline (invariant):**

```
 1. Rate Limit          ← throttle
 2. Cache check         ← short-circuit if hit
 3. Redact              ← strip sensitive input
 4. Validate (in)       ← Gladius conform on input
 5. ── Node work ──     ← LLM call + tools (per %tool-order)
 6. Structured Output   ← parse LLM text → typed data
 7. Validate (out)      ← Gladius conform on output
 8. Guard               ← content safety
 9. Redact (restore)    ← re-hydrate sensitive fields
10. Cache store         ← memoize result

Retry wraps steps 3–9.
Fallback Model retries from step 5 with alternate model.
```

Nodes declare *what* interceptors they want, not *when* they fire. The canonical order is the Interceptor Extension's responsibility.

**`%tool-order`** is exclusively for tool execution order within step 5:

```
%tool-order = [github:get_repo_conventions, github:get_pr_diff].
```

**Interceptor-managed plugin keys:**

| Key | Value type | Pipeline step | Description |
|-----|-----------|---------------|-------------|
| `%validate_in` | Spec ref or `none` | 4 | Validates input |
| `%validate_out` | Spec ref or `none` | 7 | Validates output |
| `%validate` | Spec ref or `none` | 4 + 7 | Shorthand: both |
| `%retry` | Integer | wraps 3-9 | Max attempts |
| `%structured_output` | Format or `none` | 6 | Parse LLM output |
| `%output_schema` | Spec ref or `none` | 6 | Schema for parsing |
| `%fallback_model` | Model name or `none` | retry alt | Alternate model |
| `%cache` | Duration or `off` | 2 + 10 | Memoization TTL |
| `%rate_limit` | Rate expression | 1 | Token bucket |
| `%redact` | Tag list | 3 + 9 | Strip/restore fields |
| `%guard` | Guard name or `none` | 8 | Safety filter |
| `%audit_log` | Boolean | (Extension) | Routes to Audit Log |
| `%tool-order` | List | 5 | Tool execution order |

### 6.9 Prompt and system: `<prompt=>`, `<system=>`

Freetext blocks. `%name` interpolates state. Flat only.

### 6.10 With: `<with>`

Run-level ephemeral plugins:

```
<with
  <plugin %name = debug_trace. plugin>
  <plugin %name = timeout_budget. %max = 120s. plugin>
  <plugin %name = cost_ceiling. %max = $0.50. plugin>
with>
```

### 6.11 Plugin: `<plugin>`

| Attribute | Required | Description |
|-----------|----------|-------------|
| `%name` | Yes | Plugin identifier |
| (additional) | No | Plugin-specific config |

### 6.12 Capability: `<capability>`

```
<capability
  %provides = [review:security, review:style, review:logic].
  %accepts_in : ^pr_diff_schema.
  %produces_out : ^review_output_schema.
  %tools_exposed = [review:run, review:status].
  %protocols = [A2A/1.0].
  %agent_card = '/.well-known/agent.json'.
capability>
```

**Protocol note:** ACP (IBM/BeeAI) merged into A2A (Google) under the Linux Foundation in August 2025. PXML references A2A as the unified agent-to-agent standard. The `%agent_card` attribute points to the A2A Agent Card for discovery. Legacy `ACP/1.0` protocol values are accepted and treated as `A2A/1.0`.

### 6.13 SOS Configuration: `<sos>`

Declares SOS Coding (Specification / Observation / Scenario) configuration for the pipeline. The `<sos>` block activates the Observer Extension and connects it to the Specification and Scenario stores. See section 15 for the full SOS Coding methodology.

```
<sos
  %spec = ^api_behavioral_contract.
  %scenarios = sos_store:api_scenarios.
  %observer = @sos_observer.
  %auto_generate = true.
  %reward_strategy : [pass, fail, partial] = pass.
  %on_failure : [report, halt, warn] = report.
sos>
```

| Attribute | Required | Description |
|-----------|----------|-------------|
| `%spec` | Yes | Gladius spec ref defining the behavioral contract (endogenous — visible to working agents) |
| `%scenarios` | Yes | Reference to the Scenario store collection (exogenous — invisible to working agents) |
| `%observer` | No | Named Observer agent. Default: system-provided `@sos_observer` |
| `%auto_generate` | No | Whether the Observer auto-generates scenarios from the spec. Default: `true` |
| `%reward_strategy` | No | How verdicts are issued: `pass` (binary), `fail` (strict — any failure halts), `partial` (scored). Default: `pass` |
| `%on_failure` | No | What happens when a scenario fails: `report` (log + continue), `halt` (stop pipeline), `warn` (notify + continue). Default: `report` |

**Information boundary:** The `%spec` is resolved via Gladius and is visible to all agents in the pipeline — they need it to know what to build. The `%scenarios` reference points to an external store that the Observer reads but working agents cannot access. This is the endogenous/exogenous split that makes SOS tamper-resistant.


---

## 7. Command language

Commands are the inline-mode control structure. They use bookended `/cmd ... cmd/` syntax and give users prompt-time power over the entire AAA pipeline.

### 7.1 Command syntax

**Bookended commands** contain content or parameters:

```
/prompt
  Review the PR at %pr_url for security issues.
prompt/
```

**Immediate commands** close immediately (content-less):

```
/compact/
/audit/
/abort/
```

**Parameterized commands** use attribute syntax inside the bookends:

```
/ask mode = on, freq = high, level = blocker ask/
/think depth = deep, strategy = adversarial think/
```

**Nesting** — commands can contain other commands:

```
/prompt
  Review the PR at %pr_url.
  /dry-run this first dry-run/
  Then /implement the fixes. implement/
prompt/
```

**Conditional commands:**

```
/if @security_scan found = critical
  /abort/
if/

/unless @security_scan found = clean
  /step/
unless/
```

`/if` and `/unless` are guard clauses. No `/else` — write a second guard for the alternative path. Conditionals without loops/recursion is not Turing-complete, which is a deliberate safety property.

### 7.2 Command routing

Each command targets a specific AAA stage. The stage processes its commands and passes the rest through:

| Target | Processes | Passes through |
|--------|-----------|----------------|
| Advocate (SLM) | User intent, preferences, communication style | Domain, execution, system commands |
| Analyst (MLM) | Domain context, structure, compilation | Execution, system commands |
| Agent (LLM) | Reasoning, execution, verification | System commands (handled by runtime) |
| System | Pipeline control, persistence, flow | Nothing (terminal) |

### 7.3 Command reference

#### Axis 1: Task framing — what to do

Commands that define, scope, and constrain the work.

**`/prompt ... prompt/`**
Stage: Advocate. Nests.
The compilation unit. Everything inside is a single coherent request. This is the Advocate's entry point — the outermost command that wraps a complete user intention.
- `from` — identifies the author of this prompt (optional in single-user contexts, required inside `/merge` for multiplayer contexts)

```
/prompt
  Review the PR at %pr_url for security issues.
  Have @security_scan and @logic_review run in parallel,
  then @synthesize combines their output.
prompt/
```

In a multiplayer context:
```
/prompt from = @alice
  Fix the auth bug in the login flow.
prompt/
```

**`/merge ... merge/`**
Stage: Advocate. Nests.
Combines multiple `/prompt` blocks from different users or messages into a single compiled pipeline. Designed for multiplayer contexts where 1-N humans and 0-M agents contribute prompts that need to be synthesized into one coherent execution.
- `merge-strategy` — how the Advocate combines the prompts:
  - `synthesize` (default) — read all prompts, produce one coherent pipeline addressing all of them
  - `sequential` — execute each prompt's pipeline in order
  - `parallel` — execute all prompt pipelines concurrently, merge results
  - `priority` — execute in order of sender priority (requires `%priority` on each `/prompt`)

```
/merge
  /prompt from = @alice
    Fix the auth bug in the login flow.
  prompt/

  /prompt from = @bob
    Also add rate limiting to the login endpoint.
  prompt/

  /prompt from = @charlie, %priority = 1
    Make sure any changes pass the existing test suite.
  prompt/

  /merge-strategy = synthesize
merge/
```

The Advocate sees the full set of prompts, understands the relationships between requests ("Alice wants auth fixes, Bob wants rate limiting on the same endpoint, Charlie wants test coverage"), and compiles a unified pipeline. Each prompt's `from` attribute is preserved in the compilation receipt for attribution.

In a multiplayer chat app, the main agent wraps incoming messages in a `/merge` block before handing them to the AAA pipeline. Individual messages may arrive as inline PXML or as plain text — the Advocate normalizes both.

**`/goal ... goal/`**
Stage: Advocate. Nests.
Defines what success looks like. The Advocate uses this to evaluate whether the compiled pipeline will achieve the user's objective.

```
/goal All tests pass and coverage stays above 80%. goal/
```

**`/context ... context/`**
Stage: Analyst. Nests.
Additional domain context the Analyst should factor into compilation. Not a prompt to the Agent — this is metadata about the working environment.

```
/context This repo uses event sourcing via Commanded. The schema uses CQRS with separate read/write models. context/
```

**`/assume ... assume/`**
Stage: Analyst. Nests.
Assumptions the Analyst should make without asking. Prevents unnecessary clarification round-trips.

```
/assume Postgres 16, Elixir 1.17, Phoenix 1.7. assume/
```

**`/constraint ... constraint/`**
Stage: Analyst. Nests.
Hard limits that the compiled pipeline must respect. Constraints are non-negotiable — the Analyst must honor them or fail.

```
/constraint No new dependencies. All functions must have typespecs. constraint/
```

**`/ignore ... ignore/`**
Stage: Analyst. Nests.
Things explicitly out of scope. The Analyst ensures no agent touches these.

```
/ignore Don't touch the legacy auth module or anything in lib/legacy/. ignore/
```

**`/scope ... scope/`**
Stage: Analyst. Nests.
Narrows the working area to specific files, directories, or domains. Broader than `/ignore` (which excludes) — `/scope` includes *only* what's specified.

```
/scope lib/phlox/middleware/ and test/phlox/middleware/ scope/
```

**`/pin ... pin/`**
Stage: Advocate. Nests.
Protects content from being rewritten by the Advocate or Analyst. Pinned content passes through the AAA pipeline verbatim. This is user agency — "I know what I said."

```
/pin Use exactly this error message: "Connection refused: retry in 30s." pin/
```

**`/include ... include/`**
Stage: Analyst. Nests.
Pulls in a stored PXML fragment by name or compilation ID. Templates are named compilations in the event store. The Analyst resolves and inlines them during compilation.

```
/include security_review_template/
/include pxml:a1b2c3d4/
```

**`/repo ... repo/`**
Stage: Analyst. Nests.
Creates or configures a project definition. The only command that is generative at the filesystem level. Supports nested `/use` and `/prefer` for technology selection within the project scope.
- `name` — project name
- `directory` — root directory (default `.`)
- `source-control` — `git`, `none`
- `remote` — remote repository URL
- `create` — `true` to scaffold a new project, `false` to configure existing
- `languages` — list of languages used

```
/repo name = 'phlox', directory = '.', source-control = git,
      remote = 'git@github.com:Xs-and-10s/phlox.git',
      create = true, languages = [typescript, elixir, zig]
  /use Datastar for the frontend use/
  /use Commanded for Event Sourcing use/
  /prefer bun over node always prefer/
repo/
```

The Analyst knows what `/use Phoenix` means in terms of directory structure, config files, and dependencies. The body of `/repo` can contain `/use`, `/prefer`, `/constraint`, `/ignore`, and freetext instructions.

**`/setup ... setup/`**
Stage: Analyst. Nests.
Prepares an existing project for development. Distinct from `/repo` (which creates/configures the project definition) — `/setup` handles runtime preparation: installing dependencies, running migrations, configuring services, verifying the environment.

```
/setup
  Install dependencies.
  Run database migrations.
  Seed the dev database with test fixtures.
setup/
```

Composes with `/repo`: `/repo` creates the project, `/setup` makes it runnable.

**`/use ... use/`**
Stage: Analyst. Nests.
Technology selection directive. Stronger than `/assume` (a fact) but softer than `/constraint` (non-negotiable). Binds a technology to a purpose.

```
/use Datastar for the frontend use/
/use Commanded for Event Sourcing use/
/use Gladius for all input validation use/
```

When nested inside `/repo`, `/use` directives apply to that project. When standalone, they apply to the current prompt scope. The Analyst treats `/use` as a strong preference with purpose-binding — "Datastar *for the frontend*" means Datastar is selected for frontend work specifically, not imposed globally.

Four levels of directiveness (from softest to hardest):
1. `/prefer X over Y` — ranked preference, use X when possible
2. `/use X for Y` — technology selection, strong directive
3. `/assume X` — fact about the environment, must be respected
4. `/constraint X` — non-negotiable, must be honored or fail

**`/prefer ... prefer/`**
Stage: Advocate. Nests.
Ranked preference. Softer than `/use` — "favor X over Y when there's a choice." The Advocate records this as a user preference; the Analyst respects it during compilation.

```
/prefer bun over node always prefer/
/prefer property_based tests over unit tests prefer/
/prefer GenServer over Agent for stateful processes prefer/
```

The optional `always` modifier means the preference is permanent for this session. Wrap in `/remember` for cross-session persistence:

```
/remember /prefer bun over node always prefer/ remember/
```

---

#### Axis 2: Thinking — how to reason

Commands that control reasoning depth, strategy, and self-narration.

**`/think ... think/`**
Stage: Agent. Nests.
Controls reasoning strategy for the enclosed scope. Parameters:
- `depth` — `shallow`, `normal`, `deep`
- `strategy` — `exploratory`, `adversarial`, `consensus`, `first-principles`

```
/think depth = deep, strategy = adversarial
  Is this migration safe to run on a live database?
think/
```

**`/selftalk ... selftalk/`**
Stage: Agent. Nests.
Controls how much the agent narrates its reasoning. Parameters:
- `mode` — `silent`, `visible`, `verbose`
- `detail` — `steps`, `decisions`, `all`

```
/selftalk mode = visible, detail = decisions selftalk/
```

**`/introspect ... introspect/`**
Stage: Agent. Nests.
Agent gathers knowledge about itself, the pipeline, the environment, or a compilation. Used to retrieve compilation UUIDs, inspect tool availability, review pipeline state.

```
/introspect What tools do I have access to? introspect/
/introspect Show me compilation pxml:a1b2c3d4. introspect/
```

**`/explain ... explain/`**
Stage: Agent. Nests.
Ask the agent to explain reasoning after the fact. Retrospective, not prospective.

```
/explain Why did you choose claude-opus for the security scan? explain/
```

**`/reason ... reason/`**
Stage: Agent. Nests.
Force a specific reasoning frame. The agent adopts the specified perspective for the enclosed content.

```
/reason as = devil's_advocate
  Argue against using GenServer here.
reason/
```

---

#### Axis 3: Delegation — who does it

Commands that define agents, select models, and manage tool access.

**`/agent ... agent/`**
Stage: Analyst. Nests.
Define or invoke an agent. Can declare configuration or give instructions.

```
/agent @reviewer model = claude-opus agent/
/agent @reviewer Do the security scan. Focus on injection vulnerabilities. agent/
```

**`/model = .../`**
Stage: Analyst. Immediate.
Override the default model for subsequent agents in the current scope.

```
/model = claude-opus/
```

**`/pick-tool ... pick-tool/`**
Stage: Analyst. Immediate.
Make a tool available in the current scope.

```
/pick-tool github:get_pr_diff/
```

**`/drop-tool ... drop-tool/`**
Stage: Analyst. Immediate.
Remove a tool from the current scope.

```
/drop-tool github:*/
```

**`/delegate ... delegate/`**
Stage: Agent. Nests.
Hand off work to a sub-agent with specific instructions. Unlike `/agent` (which defines at compile time), `/delegate` is a runtime instruction.

```
/delegate @linter Check for style issues only. Ignore naming conventions. delegate/
```

**`/as ... as/`**
Stage: Agent. Nests.
Adopt a persona or role. This doesn't just set tone — it tells the Analyst to select tools, model, and interceptors appropriate for that role. The persona configures the pipeline.

```
/as senior_security_engineer
  Review this authentication flow.
as/
```

**`/task ... task/`**
Stage: Agent. Nests.
Assigns a named, trackable unit of work to an agent. Distinct from `/focus` (which narrows attention) and `/delegate` (which hands off to a sub-agent). `/task` defines *what specific thing to do*. An agent can have multiple tasks, and each appears independently in the execution trace.

```
/agent @reviewer model = claude-opus
  /task Check for SQL injection task/
  /task Check for XSS vulnerabilities task/
  /task Check for auth bypass task/
agent/
```

Tasks compose with `/focus`:

```
/agent @performance_reviewer model = claude-opus
  /task focus on N+1 queries and memory allocation task/
  /focus latency, throughput focus/
agent/
```

In the execution trace, each task produces a separate `TaskCompleted` or `TaskFailed` event, enabling granular reporting. `/report` can target individual tasks: `/report on = @reviewer:sql_injection report/`.

**`/message ... message/`**
Stage: Agent (runtime execution), Analyst (compile-time validation). Nests.
Inter-pipeline agent-to-agent communication via the A2A protocol (the unified standard after ACP merged into A2A in August 2025). The runtime companion to the static `<capability>` declaration. `/delegate` is intra-pipeline (sub-agent); `/message` is inter-pipeline (foreign namespace). Gladius enforces contracts on both sides: the sender validates via `expect`, the receiver validates via `%accepts_in` in its `<capability>`.

This is distinct from MCP, which handles tool invocation (model→tool). `/message` handles agent communication (agent↔agent). MCP tools are managed via `/pick-tool` and `/drop-tool`. `/message` operates at the agent layer above.

- `to` — target namespace (`PXML:org:...`) or glob (`*`) for A2A discovery
- `action` — capability to invoke (must match target's `<capability %provides>`)
- `payload` — list of state variables or values to send
- `expect` — Gladius spec ref for expected response shape (validated on arrival)
- `timeout` — how long to wait for response
- `await` — `true` (default, wait for response) or `false` (fire-and-forget)
- `protocol` — `a2a` (default), `auto`. Reserved for forward-compatibility with future protocols.

Request-response (invoke and wait):
```
/message to = PXML:org:acme:reviewer,
         action = review:run,
         payload = [%pr_diff],
         expect : ^review_output,
         timeout = 60s
message/
```

Fire-and-forget (notify without waiting):
```
/message to = PXML:org:acme:logger,
         action = log:event,
         payload = [%findings],
         await = false
message/
```

Broadcast (discover and invoke all matching namespaces):
```
/message to = *,
         action = review:*,
         payload = [%pr_diff],
         expect : ^review_output
message/
```

The glob on `to` and `action` discovers all namespaces advertising matching capabilities via their `<capability %provides>` declarations.

Events: `MessageSent`, `MessageReceived`, `MessageFailed` — each with `from_namespace`, `to_namespace`, `action`, `payload_hash`, `duration_ms`.

---

#### Axis 4: Communication — how to talk to me

Commands that control output format, verbosity, tone, and interaction style.

**`/format ... format/`**
Stage: Agent. Nests.
Control output shape. Parameters:
- `type` — `markdown`, `json`, `plain`, `structured`
- `sections` — list of section names

```
/format type = markdown, sections = [summary, details, next_steps] format/
```

**`/tone = .../`**
Stage: Advocate. Immediate.
Set communication style. Options: `direct`, `teaching`, `casual`, `formal`, `socratic`.

```
/tone = direct/
```

**`/communication ... communication/`**
Stage: Agent. Nests.
Full-featured control over output verbosity and detail level. `/compact/` and `/verbose` are shorthands for common configurations of this command.
- `output` — `terse`, `normal`, `verbose`
- `detail` — `steps`, `decisions`, `reasoning`, `all`

```
/communication output = terse communication/
/communication output = verbose, detail = reasoning communication/
/communication output = normal, detail = decisions communication/
```

**`/compact/`**
Stage: Agent. Immediate.
Shorthand for `/communication output = terse communication/`. Minimize output — no preamble, no caveats, just the answer. This controls *verbosity*, not state (see `/compaction` for state compression).

**`/compaction ... compaction/`**
Stage: System. Nests.
Triggers state compression — summarizes conversation history, compresses shared state, reclaims context window. The Advocate produces the summary. A `StateCompacted` event is recorded.
- `scope` — `conversation`, `state`, `all`

```
/compaction scope = conversation compaction/
/compaction scope = all compaction/
```

**`/verbose = .../`**
Stage: Agent. Immediate.
Shorthand for `/communication output = verbose, detail = ... communication/`. Options: `reasoning`, `all`.

```
/verbose = reasoning/
/verbose = all/
```

**`/ask ... ask/`**
Stage: Advocate. Nests.
Control when and how the pipeline asks the user questions. Parameters:
- `mode` — `on`, `off`, `once`
- `freq` — `low`, `normal`, `high`
- `level` — `any`, `important`, `blocker`

```
/ask mode = on, freq = high, level = blocker ask/
```

**`/me ... me/`**
Stage: Advocate. Nests.
User self-description. The Advocate uses this to personalize the compilation — adjusting tone, assumed expertise level, and communication style.

```
/me I'm senior-level, prefer terse answers, use Elixir daily. me/
```

**`/focus ... focus/`**
Stage: Agent. Nests.
Narrows the agent's conceptual attention to specific aspects. Unlike `/scope` (which narrows file/code scope), `/focus` narrows what the agent thinks about.

```
/focus error_handling, edge_cases focus/
```

---

#### Axis 5: Protection — what to guard

Commands that control security, privacy, and cost.

**`/redact ... redact/`**
Stage: Analyst. Nests.
Mark content categories for redaction. Maps to the Redact interceptor plugin.

```
/redact #api_keys #credentials #env_vars redact/
```

**`/cost ... cost/`**
Stage: System. Nests.
Cost controls for the run. Maps to the Cost Ceiling plugin.

```
/cost max = $0.50, warn_at = $0.30 cost/
```

**`/timeout = .../`**
Stage: System. Immediate.
Wall-clock limit for the entire run. Maps to the Timeout Budget plugin.

```
/timeout = 120s/
```

**`/sandbox ... sandbox/`**
Stage: Analyst. Nests.
Restrict the execution environment. Limits what tools and resources agents can access.

```
/sandbox no_network, read_only = [/src], write_only = [/tmp] sandbox/
```

**`/audit/`**
Stage: System. Immediate.
Enable full audit trail for this run. Sets `%audit_log = true` on all agents.

**`/harness ... harness/`**
Stage: System. Nests.
Select, configure, and introspect the active harness system. A harness is the cross-cutting safety/observability layer that wraps the entire pipeline. PXML supports swappable harness implementations (e.g., Tao, Pi) that respond to this command.
- `name` — harness implementation name
- `version` — harness version
- `introspect` — query the active harness's capabilities and configuration

Configuration mode (select and configure):
```
/harness name = tao, version = 0.1.0
  circuit_breaker = on,
  fallback_strategy = cascade,
  guardrails = [content_safety, pii_detection],
  telemetry = verbose,
  cost_policy = warn_at_80_percent
harness/
```

Introspection mode (query current harness):
```
/harness introspect harness/
```

Runtime reconfiguration (change settings mid-pipeline):
```
/harness
  telemetry = silent,
  circuit_breaker = off
harness/
```

The harness implementation determines which configuration keys are valid. PXML defines the command interface; the harness defines the configuration schema.

**`/customize ... customize/`**
Stage: System. Nests.
Configures the Phlox runtime execution characteristics — how the engine itself behaves, as opposed to what runs on it. `<defaults>` configures agents. `/customize` configures the engine underneath them.
- `concurrency` — max parallel agent executions (integer)
- `buffer` — GenStage buffer settings: `max_demand`, `min_demand`
- `error_strategy` — `halt_on_error`, `continue_on_error`, `isolate_failures`
- `state_backend` — `ets`, `persistent_term`, `ecto`
- `checkpoint_strategy` — `manual` (only on `/snapshot`), `auto` (after each phase), `off`
- `gc_pressure` — `low`, `normal`, `high` (hint to the runtime about memory management)

```
/customize
  concurrency = 4,
  buffer = [max_demand = 2, min_demand = 1],
  error_strategy = continue_on_error,
  state_backend = ets,
  checkpoint_strategy = auto
customize/
```

Minimal form for a single override:
```
/customize concurrency = 8 customize/
```

---

#### Axis 6: Verification — how to check the work

Commands that control testing, validation, critique, and approval.

**`/critique ... critique/`**
Stage: Agent. Nests.
Run critical analysis on work. Can target specific aspects.

```
/critique security, performance, readability critique/
```

**`/validate ... validate/`**
Stage: Analyst. Nests.
Validate a target against a Gladius spec. Maps to the Validate interceptor plugin.
- `target` — `input`, `output`, a `%state_variable`, or `@agent_name` (validate that agent's last output retroactively)
- `against` — a `^spec_ref`

```
/validate target = output, against = ^output_schema validate/
/validate target = %findings, against = ^findings_list validate/
/validate target = @security_scan, against = ^findings_list validate/
```

**`/test ... test/`**
Stage: Agent. Nests.
Generate or run tests. Parameters:
- `coverage` — `happy_path`, `edge_cases`, `exhaustive`
- `style` — `unit`, `property_based`, `integration`

```
/test coverage = edge_cases, style = property_based test/
```

**`/dry-run ... dry-run/`**
Stage: System. Nests.
Simulate without executing LLM calls. Returns execution plan and cost estimate. Can wrap specific sections to dry-run only part of the pipeline.

```
/dry-run this section dry-run/
```

**`/review ... review/`**
Stage: Agent. Nests.
Peer review by a different agent or model.

```
/review by = @senior_reviewer review/
```

**`/compare ... compare/`**
Stage: Agent. Nests.
Compare approaches on specified criteria.

```
/compare [approach_a, approach_b] on = [perf, readability, cost] compare/
```

**`/diff ... diff/`**
Stage: System. Nests.
Compare two compilations, revisions, or agent outputs. Projects the DiffView from the event store.

```
/diff pxml:a1b2c3d4 pxml:e5f6a7b8 diff/
/diff @security_scan @logic_review diff/
```

---

#### Axis 7: Memory — what to remember

Commands that control persistence, recall, and session scope.

**`/session ... session/`**
Stage: System. Nests.
Session-scoped directives. Applies to this conversation only. Lost when the session ends.

```
/session All code in this session uses Elixir 1.18 with OTP 27. session/
```

**`/remember ... remember/`**
Stage: System. Nests.
Cross-session memory. Persisted to user profile via the event store.

```
/remember I prefer GenServer over Agent for stateful processes. remember/
```

**`/forget ... forget/`**
Stage: System. Nests.
Remove from cross-session memory.

```
/forget preference about GenServer. forget/
```

**`/recall ... recall/`**
Stage: Advocate. Nests.
Explicitly pull from memory. The Advocate uses recalled information to inform intent clarification.

```
/recall What do I prefer for state management? recall/
```

**`/snapshot = .../`**
Stage: System. Immediate.
Save current pipeline state as a named checkpoint.

```
/snapshot = before_refactor/
```

**`/replay = .../`**
Stage: System. Immediate.
Re-execute a stored compilation from the event store.

```
/replay = pxml:a1b2c3d4/
```

**`/alias ... alias/`**
Stage: System. Nests.
Name a reusable command pattern. Session-scoped by default. Wrap in `/remember` for cross-session persistence.

```
/alias /sec-review = /agent @scanner model = opus /critique security /validate ^findings alias/
```

Then invoke: `/sec-review/`

To persist: `/remember /alias /sec-review = ... alias/ remember/`

---

#### Axis 8: Flow control — when and how to proceed

Commands that control execution order, conditions, pausing, iteration, and composition.

**`/plan ... plan/`**
Stage: Analyst. Nests.
Show the execution plan before running. The Analyst's compiled PXML is presented to the user with its compilation receipt. Can request approval before proceeding.

```
/plan then ask me before proceeding. plan/
```

**`/step/`**
Stage: System. Immediate.
Execute one agent at a time, pausing between each. The user must approve each step. Optionally takes a count: `/step = 3/` means "execute the next 3 agents, then pause again." The counterpart is `/run/`.

```
/step/
/step = 3/
```

**`/run/`**
Stage: System. Immediate.
Resume normal (non-paused) execution after `/step/`. The debugger metaphor: `/step/` is step-through, `/run/` is continue. If execution is not currently paused, `/run/` is a no-op.

**`/checkpoint ... checkpoint/`**
Stage: System. Nests.
Insert a human-in-the-loop approval gate at a specific point.

```
/checkpoint after = @security_scan, require = human_approval checkpoint/
```

**`/retry ... retry/`**
Stage: Agent. Nests.
Re-run with modifications.

```
/retry with = different_model retry/
/retry approach = from_scratch retry/
```

**`/abort/`**
Stage: System. Immediate.
Stop everything. Immediately. Always records an `ExecutionFailed` event with the abort reason, the last agent's state, and a summary of what completed before the abort. This is a *structured system report* in the event store — not a natural-language explanation. For a human-readable post-mortem, use `/report`.

**`/report ... report/`**
Stage: Agent. Nests.
Produce a natural-language explanation of an execution. Unlike `/abort/` (which records structured trace data automatically), `/report` asks the Agent to reason about what happened and explain it in plain language.
- `on` — a `pxml:shortid`, `@agent_name`, or `last` (most recent execution)
- `why` — focus the explanation on a specific agent or event

```
/report on = last report/
/report on = pxml:a1b2c3d4, why = @security_scan report/
```

Composes with `/abort/` but neither requires the other:

```
/if @security_scan found = critical
  /report why = @security_scan report/
  /abort/
if/
```

**`/rollback = .../`**
Stage: System. Immediate.
Revert to a named snapshot.

```
/rollback = before_refactor/
```

**`/iterate ... iterate/`**
Stage: Agent. Nests.
Refine previous output. The `keep` parameter preserves specified aspects; `focus` targets what to improve. Maps to partial cache hits via the Cache interceptor.

```
/iterate focus = error_handling, keep = architecture iterate/
```

**`/research ... research/`**
Stage: Agent. Nests.
Deep research mode. Broader search, more sources, synthesis across findings.

```
/research GenStage backpressure patterns in production research/
```

**`/investigate ... investigate/`**
Stage: Agent. Nests.
Focused exploration of a specific thing. Narrower than `/research`.

```
/investigate Why is this test flaky? Check timing and shared state. investigate/
```

**`/implement ... implement/`**
Stage: Agent. Nests.
Skip planning, go straight to code execution. The agent writes code rather than discussing it.

```
/implement the retry logic we discussed. implement/
```

**`/if ... if/`**
Stage: System. Nests.
Conditional guard clause. Executes its body only if the condition is true. No `/else` — write a second guard for the alternative path.

Not Turing-complete: conditionals without loops/recursion form a finite decision tree.

```
/if @security_scan found = critical
  /abort/
if/

/if @style_check found = none
  /compact/
  Skip synthesis — no style issues.
if/
```

**`/unless ... unless/`**
Stage: System. Nests.
Negated guard clause. Executes its body only if the condition is false. More readable than `/if found != clean` for safety-oriented guards.

```
/unless @security_scan found = clean
  /step/
unless/
```

**`/extend ... extend/`**
Stage: Analyst. Nests.
Takes a previous compilation and adds to it. Creates a new compilation with `parent_id` pointing to the original. Supports both structured parameters (precise, machine-executable additions) and freetext body (fuzzy modifications the Analyst interprets).
- `to` — parent compilation ref (`pxml:shortid`)
- `agents` — list of `@agent` refs to add
- `tools` — list of tool names to add
- `plugins` — list of plugin names to add

```
/extend to = pxml:a1b2c3d4,
        agents = [@performance_reviewer],
        tools = [profiler:flamegraph],
        plugins = [seed_pin]
  /agent @performance_reviewer model = claude-opus
    Focus on N+1 queries and memory allocation.
  agent/
extend/
```

The structured parameters are precise additions the parser executes deterministically. The body provides detailed configuration and natural-language instructions the Analyst interprets. Both are optional — you can extend with only structured params, only a body, or both.

**`/without ... without/`**
Stage: Analyst. Nests.
Inverse of `/extend`. Takes a previous compilation and removes from it. Supports both structured parameters (precise, machine-executable removals) and freetext body (fuzzy modifications the Analyst interprets). Creates a new compilation with `parent_id` pointing to the original.
- `from` — parent compilation ref (`pxml:shortid`)
- `agents` — list of `@agent` refs to remove
- `tools` — list of tool names to remove
- `plugins` — list of plugin names to remove

```
/without from = pxml:a1b2c3d4,
         agents = [@style_check],
         tools = [tool_1, tool_3],
         plugins = [debug_trace]
  Also lower all retries to 1.
without/
```

The structured parameters are precise subtractions the parser executes deterministically. The body is fuzzy modification the Analyst interprets. The symmetry with `/extend` is deliberate — they are the same operation with opposite signs.

**`/notify ... notify/`**
Stage: System. Nests.
Sets up event-driven notifications routed to external channels. Unlike `/checkpoint` (which pauses for human approval), `/notify` alerts without pausing. Long-running pipelines need to signal progress, warnings, or completions to humans without blocking execution.
- `on` — delivery channel: `slack`, `email`, `sse`, `webhook`
- `when` — event condition: `@agent completes`, `@agent fails`, `cost > $N.NN`, `any_agent_fails`, `pipeline_completes`
- `to` — recipient (optional, defaults to pipeline owner): `@mark`, `#team-channel`, email address

```
/notify on = slack, when = @security_scan completes, to = #review-channel notify/
/notify on = email, when = cost > $0.30 notify/
/notify on = sse, when = any_agent_fails notify/
/notify on = webhook, when = pipeline_completes,
        to = 'https://hooks.acme.com/pxml' notify/
```

Composes naturally with the event-sourced persistence — notifications are event handlers that listen to the execution trace stream.

---

#### Axis 9: Observation — how to verify integrity

Commands that control SOS Coding (Specification / Observation / Scenario). These enable tamper-resistant verification of agent work by enforcing an information boundary between working agents and test scenarios. See section 15 for the full SOS methodology.

**`/observe ... observe/`**
Stage: System. Nests.
Activates SOS Coding for a scope. The Observer Extension begins watching the specified area of the codebase, evaluating working agents' output against Scenarios they cannot see.
- `scope` — what to observe: a file path, module name, `@agent` ref, or `all`
- `spec` — Gladius spec ref for the behavioral contract (optional if `<sos>` block already declares it)
- `strategy` — `continuous` (watch and re-evaluate on every change), `on_complete` (evaluate once after pipeline finishes). Default: `on_complete`

```
/observe scope = lib/phlox/middleware/, spec = ^middleware_contract observe/
/observe scope = @security_scan, strategy = continuous observe/
/observe scope = all observe/
```

When used inside `/prompt` in inline mode:
```
/prompt
  Refactor the auth module.
  /observe scope = lib/auth/ observe/
prompt/
```

The Observer is activated but the working agents implementing the refactor do not know they are being observed or what the Scenarios test for.

**`/scenario ... scenario/`**
Stage: System. Nests.
Adds a scenario to the exogenous Scenario store. Scenarios are written as natural-language prompts in GWT (Given-When-Then) style. They are visible only to the Observer — working agents never see them. Scenarios are immutable once committed.
- `for` — Gladius spec ref or scope that this scenario tests against
- `by` — who authored the scenario: `auto` (Observer-generated), `@human_name`, `system`
- `priority` — `critical`, `normal`, `low`. Default: `normal`

```
/scenario for = ^auth_contract, priority = critical
  Given a user with an expired session token,
  When they attempt to access /api/dashboard,
  Then the system returns 401 with a JSON body containing a `redirect_url` field.
scenario/

/scenario for = ^auth_contract
  Given a user with a valid session but insufficient permissions,
  When they attempt to delete another user's account,
  Then the system returns 403 and logs the attempt to the audit trail.
scenario/

/scenario for = ^validation_contract, by = auto
  ~~ Observer auto-generates: this scenario was inferred from the spec ~~
scenario/
```

**Key properties of scenarios:**
- **Exogenous:** Stored outside the PXML document in a separate, agent-inaccessible store.
- **Immutable:** Once committed, a scenario cannot be modified or deleted by agents. Only humans or system administrators can retire scenarios.
- **Natural language:** Written as prompts the Observer interprets, not as code. This means the Observer (an LLM) evaluates whether the codebase behavior matches the scenario's intent — it's not pattern-matching strings.
- **Attributable:** The `by` attribute tracks whether the scenario was human-authored or auto-generated, enabling different confidence weighting in verdicts.


---

## 8. Compilation receipt

Every compiled PXML document produces a receipt visible to the user at three lifecycle points: after compilation (plan view), during execution (response header), and after completion (in stored trace).

### 8.1 Receipt format

```
┌ pxml:a1b2c3d4 · rev:1 · compiled 2026-04-08T10:30:00Z
│ ns: PXML:org:pxml:brain-trust
│ agents: @security_scan @style_check @logic_review @synthesize
│ model: claude-sonnet (default) · opus (security_scan, logic_review)
│ interceptors: validate, retry, structured_output, guard
│ plugins: debug_trace, timeout_budget (120s), cost_ceiling ($0.50)
│ cost: $0.00 (dry-run) · tokens: 0
│ parent: none · revision: 1
└──────────────────────────────────────────
```

### 8.2 Receipt fields

| Field | Description |
|-------|-------------|
| `pxml:shortid` | First 8 characters of the compilation UUID. System resolves to full UUID. |
| `rev` | Revision number within the parent chain |
| `compiled` | ISO 8601 timestamp |
| `ns` | Namespace from the root element |
| `agents` | All `@agent` names in the pipeline |
| `model` | Default model + any overrides |
| `interceptors` | Active interceptor plugins across all agents (deduplicated) |
| `plugins` | Run-level plugins from `<with>` with their configuration |
| `cost` | Estimated or actual cost. Shows `(dry-run)` if not yet executed. |
| `tokens` | Total tokens in/out. `0` before execution. |
| `parent` | Parent compilation ID if this is an `/extend` or `/without` revision. `none` otherwise. |
| `revision` | Revision number. `1` for original compilations. |

### 8.3 Receipt visibility

**On the prompt side (after compilation):**
When the Analyst completes compilation, the receipt is shown above the compiled PXML. If `/plan` was used, the user sees the receipt + compiled document and can approve, modify, or cancel.

**On the response side (during execution):**
The receipt is prepended to the Agent's first response. As execution proceeds, the `cost` and `tokens` fields update.

**In the event store:**
The `InlineCompiled` event contains the full receipt data. Projections (`CompilationSummary`, `ExecutionTrace`) include receipt fields for querying.

### 8.4 Referencing compilations

Users reference compilations by short ID:

```
/extend pxml:a1b2c3d4
  Add @performance_reviewer.
extend/

/replay = pxml:a1b2c3d4/
/diff pxml:a1b2c3d4 pxml:e5f6a7b8 diff/
/introspect Show me compilation pxml:a1b2c3d4. introspect/
```

The `pxml:` prefix disambiguates compilation IDs from other UUIDs. The runtime resolves short IDs (8 chars) to full UUIDs. If ambiguous (multiple compilations share a prefix), the system prompts for disambiguation.


---

## 9. Compilation target

| PXML element | Phlox struct / concept |
|-------------|------------------------|
| `<pxml>` | `%Phlox.Graph{}` |
| `<defaults>` | Default config on graph |
| `<state>` | Typed shared state (V2.8) |
| `<prep>` / `<exec>` / `<post>` | Phase groupings |
| `<agent>` | `%Phlox.Node{}` |
| `<plan>` | Subgraph with orchestration strategy |
| `<intercept>` | Interceptor Extension declarations on node |
| `<pick-tool>` / `<drop-tool>` | Tool scope mutations |
| `<prompt=>` / `<system=>` | Prompt template fields |
| `<with>` | Plugin list for `Phlox.run/2` |
| `<capability>` | Metadata (A2A Agent Card for discovery) |
| `<sos>` | Observer Extension configuration + Scenario store binding |
| `^spec_ref` | `Gladius.Registry.fetch!/1` |

### The phlox_gladius bridge

```
phlox  ←── phlox_gladius ──→  gladius
              ↑
             pxml (uses the bridge during compilation and execution)
```

`phlox_gladius` provides:

- `PhloxGladius.InterceptorExtension` — the Interceptor Extension
- `PhloxGladius.ValidatePlugin` — calls `Gladius.conform/2` at steps 4 and 7
- `PhloxGladius.StructuredOutputPlugin` — parses and validates LLM output
- `PhloxGladius.install(graph)` — registers the extension on a Phlox graph


---

## 10. Persistence layer (CQRS / Event Sourcing)

### 10.1 Aggregate: Compilation

**Commands:**

| Command | Description |
|---------|-------------|
| `CompileInline` | Compile inline text into block mode |
| `CompileBlock` | Register a hand-authored block document |
| `ReviseCompilation` | Create a new revision (from `/extend` or `/without`) |
| `BeginExecution` | Mark as executing |
| `RecordAgentStart` | Agent started |
| `RecordAgentComplete` | Agent completed |
| `RecordAgentFailure` | Agent failed |
| `RecordToolInvocation` | Tool invoked during node work |
| `RecordInterceptorResult` | Interceptor plugin result |
| `CompleteExecution` | Pipeline completed |
| `FailExecution` | Pipeline failed |
| `MarkIncomplete` | Stream terminated before `pxml>` closed |
| `SaveSnapshot` | Named checkpoint (from `/snapshot`) |
| `StoreAlias` | Named command pattern (from `/alias`) |
| `StoreMemory` | Cross-session memory (from `/remember`) |
| `RemoveMemory` | Memory removal (from `/forget`) |
| `CompactState` | State compression (from `/compaction`) |

**Events:**

| Event | Key fields |
|-------|------------|
| `InlineCompiled` | `inline_text`, `inline_sigils`, `block_text`, `block_ast`, `compiler_model`, `compiler_reasoning`, `system_defaults`, `namespace`, `receipt`, `compiled_at` |
| `BlockRegistered` | `block_text`, `block_ast`, `namespace`, `receipt`, `registered_at` |
| `CompilationRevised` | `parent_id`, `revision`, `revision_type` (extend/without), `revision_params` (structured additions/removals), `inline_text`, `block_text`, `block_ast`, `receipt`, `revised_at` |
| `ExecutionStarted` | `phlox_graph_id`, `started_at` |
| `AgentStarted` | `agent_name`, `phase`, `tools_available`, `interceptors_active`, `started_at` |
| `AgentCompleted` | `agent_name`, `phase`, `input_hash`, `output_hash`, `model_used`, `tokens_in`, `tokens_out`, `duration_ms`, `tools_invoked`, `completed_at` |
| `AgentFailed` | `agent_name`, `phase`, `error`, `retry_count`, `failed_at` |
| `TaskStarted` | `agent_name`, `task_name`, `started_at` |
| `TaskCompleted` | `agent_name`, `task_name`, `output_hash`, `duration_ms`, `completed_at` |
| `TaskFailed` | `agent_name`, `task_name`, `error`, `failed_at` |
| `ToolInvoked` | `agent_name`, `tool_name`, `input_hash`, `output_hash`, `duration_ms`, `invoked_at` |
| `InterceptorResultRecorded` | `agent_name`, `plugin_name`, `pipeline_step`, `result`, `recorded_at` |
| `ExecutionCompleted` | `total_tokens_in`, `total_tokens_out`, `total_duration_ms`, `total_cost`, `receipt`, `completed_at` |
| `ExecutionFailed` | `error`, `last_agent`, `failed_at` |
| `MarkedIncomplete` | `last_complete_element`, `buffer_state`, `marked_at` |
| `SnapshotSaved` | `snapshot_name`, `pipeline_state`, `saved_at` |
| `AliasStored` | `alias_name`, `alias_body`, `scope` (session/permanent), `stored_at` |
| `MemoryStored` | `memory_text`, `memory_key`, `stored_at` |
| `MemoryRemoved` | `memory_key`, `removed_at` |
| `StateCompacted` | `scope` (conversation/state/all), `summary`, `tokens_before`, `tokens_after`, `compacted_at` |
| `MessageSent` | `from_namespace`, `to_namespace`, `action`, `payload_hash`, `await`, `sent_at` |
| `MessageReceived` | `from_namespace`, `to_namespace`, `action`, `response_hash`, `duration_ms`, `received_at` |
| `MessageFailed` | `from_namespace`, `to_namespace`, `action`, `error`, `failed_at` |
| `NotificationSent` | `channel`, `condition`, `recipient`, `sent_at` |
| `RuntimeCustomized` | `settings`, `previous_settings`, `customized_at` |
| `HarnessConfigured` | `harness_name`, `harness_version`, `settings`, `configured_at` |
| `MergeCompiled` | `prompt_sources` (list of `{from, inline_text}`), `merge_strategy`, `block_text`, `block_ast`, `receipt`, `compiled_at` |
| `ScenarioCreated` | `scenario_id`, `spec_ref`, `given_text`, `when_text`, `then_text`, `authored_by`, `source`, `priority`, `created_at` |
| `ScenarioRetired` | `scenario_id`, `retired_by`, `reason`, `retired_at` |
| `ScenarioEvaluated` | `scenario_id`, `compilation_id`, `verdict` (pass/fail/partial), `confidence`, `reasoning`, `code_evidence`, `evaluated_at` |
| `ObservationCompleted` | `compilation_id`, `spec_ref`, `total_scenarios`, `passed`, `failed`, `partial`, `aggregate_score`, `observer_model`, `completed_at` |
| `VerdictAppealed` | `scenario_id`, `compilation_id`, `appealed_by`, `appeal_reasoning`, `appealed_at` |
| `VerdictOverridden` | `scenario_id`, `compilation_id`, `overridden_by`, `new_verdict`, `override_reasoning`, `overridden_at` |

### 10.2 Read models (projections)

**CompilationSummary:** Current state of a compilation — status, agents, receipt, lineage.

**ExecutionTrace:** Per-agent execution detail — tools available vs. invoked, interceptor results, tokens, duration.

**CostReport:** Aggregated cost per namespace per period.

**DiffView:** Comparison between compilation revisions. Projects `CompilationRevised` events.

**AliasRegistry:** Active command aliases per user per session.

**MemoryStore:** Cross-session user memories.


---

## 11. Grammar implementation

### 11.1 nimble_parsec

Stack-based parser, GenStage producer. Emits complete bookended elements into the downstream buffer.

Key concerns:
- Command bookends (`/cmd ... cmd/`) must be parsed alongside element bookends (`<tag ... tag>`)
- Freetext modes: `<tag= =tag>`, backtick fences, and single-quoted literals all suppress sigil parsing
- Greedy numeric parsing for the `.` terminator ambiguity
- Comments (`~~ ... ~~`) stripped during tokenization
- Structured errors with line/column

### 11.2 Tree-sitter

Enables syntax highlighting in Neovim, VS Code, Helix, Monologue. Targets incremental reparsing. Injection for PXML inside markdown fences (` ```pxml `). Freetext and code blocks fall back to appropriate highlighting.


---

## 12. Inline mode

### 12.1 Extraction rules

| Sigil | Pattern | Extraction |
|-------|---------|------------|
| `/cmd ... cmd/` | Bookended command | Command with body |
| `/cmd/` | Self-closing command | Immediate command |
| `@` | `@word` | Agent/human mention |
| `^` | `^word` | Spec ref |
| `#` | `#word` | Tag |
| `%` | `%word` | State variable reference |
| `$` | `$N.NN` | Currency value |
| `Ns/Nh/Nm` | Number + time unit | Duration |
| `'...'` | Single-quoted span | Literal |
| `` `...` `` | Backtick span | Code |
| ```` ```...``` ```` | Fenced block | Code block |
| `pxml:xxxxxxxx` | 8-char hex after `pxml:` | Compilation reference |

### 12.2 Full inline example

```
/prompt
  /me I'm senior-level, use Elixir daily. me/
  /tone = direct/
  /goal All security issues identified with zero false positives. goal/
  /context This repo uses event sourcing via Commanded. context/
  /assume Postgres 16, Elixir 1.17. assume/

  Review the PR at %pr_url for security issues.
  Have @security_scan and @logic_review run in parallel,
  then @synthesize combines their output.

  /agent @security_scan model = claude-opus agent/
  /agent @logic_review model = claude-opus agent/

  Validate all findings against ^findings_list.
  /redact #env_vars #api_keys redact/

  /cost max = $0.50, warn_at = $0.30 cost/
  /timeout = 120s/

  /if @security_scan found = critical
    /report why = @security_scan report/
    /abort/
  if/

  /unless @security_scan found = clean
    /checkpoint after = @security_scan, require = human_approval checkpoint/
  unless/

  /think depth = deep, strategy = adversarial
    Could any of these findings be false positives?
  think/

  /critique security critique/
  /test coverage = edge_cases test/

  /dry-run this first dry-run/ so I can see the cost.
prompt/
```


---

## 13. Full block mode example

```
<pxml %ns = PXML:org:pxml:brain-trust.
  %version = 0.2.2.
  %context = codex.pxml.org
  %compilation_id = a1b2c3d4-5e6f-7890-abcd-ef1234567890.
  %compiled_at = 2026-04-08T10:30:00Z.
  %parent_id = none.
  %revision = 1.

  <defaults
    %model = claude-sonnet.
    %timeout = 30s.
    %on-failure = warn.
    %retry = 2.
    %structured_output = none.
    %output_schema = none.
    %fallback_model = none.
    %cache = off.
    %rate_limit = 10/min.
    %redact = [].
    %guard = none.
    %audit_log = false.
    %tool-inheritance = inherit.
  defaults>

  <state
    %pr_diff   : ^diff_schema.
    %findings  : ^findings_list.
    %review    : ^review_output.
  state>

  <capability
    %provides = [review:security, review:style, review:logic, review:synthesized].
    %accepts_in : ^diff_schema.
    %produces_out : ^review_output.
    %protocols = [A2A/1.0].
    %agent_card = '/.well-known/agent.json'.
  capability>

  <prep
    <agent %name = fetch_context.
      %model = claude-sonnet.
      %depends_on = [].
      %timeout = 30s.
      %on-failure = warn.
      <drop-tool %name = github:*. drop-tool>
      <pick-tool %name = github:get_pr_diff. pick-tool>
      <pick-tool %name = github:get_repo_conventions. pick-tool>
      <intercept
        %validate_in = none.
        %validate_out = ^diff_schema.
        %retry = 2.
        %structured_output = none.
        %output_schema = none.
        %fallback_model = none.
        %cache = off.
        %rate_limit = 10/min.
        %redact = [].
        %guard = none.
        %audit_log = false.
        %timeout = 10s.
        %tool-order = [github:get_repo_conventions, github:get_pr_diff].
      intercept>
    agent>
  prep>

  <exec
    <plan %orchestration = parallel.

      <agent %name = security_scan.
        %model = claude-opus.
        %depends_on = [].
        %timeout = 30s.
        %on-failure = warn.
        <intercept
          %validate_in = none.
          %validate_out = ^findings_list.
          %retry = 3.
          %structured_output = json.
          %output_schema = json_schema.
          %fallback_model = none.
          %cache = off.
          %rate_limit = 10/min.
          %redact = [#env_vars, #api_keys].
          %guard = block_if_hallucinated_cve.
          %audit_log = false.
        intercept>
        <prompt=
          Review this diff for security vulnerabilities.
          Focus on: injection, auth bypass, secret leakage.
          Cite exact line numbers from %pr_diff.
        =prompt>
      agent>

      <agent %name = style_check.
        %model = claude-haiku.
        %depends_on = [].
        %timeout = 30s.
        %on-failure = warn.
        <intercept
          %validate_in = none.
          %validate_out = ^findings_list.
          %retry = 2.
          %structured_output = none.
          %output_schema = none.
          %fallback_model = claude-sonnet.
          %cache = 1h.
          %rate_limit = 10/min.
          %redact = [].
          %guard = none.
          %audit_log = false.
        intercept>
      agent>

      <agent %name = logic_review.
        %model = claude-opus.
        %depends_on = [].
        %timeout = 30s.
        %on-failure = warn.
        <intercept
          %validate_in = none.
          %validate_out = ^findings_list.
          %retry = 2.
          %structured_output = none.
          %output_schema = none.
          %fallback_model = none.
          %cache = off.
          %rate_limit = 10/min.
          %redact = [#env_vars, #api_keys].
          %guard = none.
          %audit_log = false.
        intercept>
      agent>

    plan>

    <agent %name = synthesize.
      %model = claude-sonnet.
      %depends_on = [@security_scan, @style_check, @logic_review].
      %timeout = 30s.
      %on-failure = warn.
      <intercept
        %validate_in = ^findings_list.
        %validate_out = ^review_output.
        %retry = 2.
        %structured_output = json.
        %output_schema = json_schema.
        %fallback_model = none.
        %cache = off.
        %rate_limit = 10/min.
        %redact = [].
        %guard = none.
        %audit_log = false.
      intercept>
      <prompt=
        Synthesize findings from all three reviewers.
        Deduplicate, rank by severity, produce a single review.
        Keep the tone constructive — this ships to a human.
      =prompt>
    agent>
  exec>

  <post
    <agent %name = publish.
      %model = claude-sonnet.
      %depends_on = [].
      %timeout = 30s.
      %on-failure = warn.
      <pick-tool
          %name = hook:on-enter:lint.
          %on-failure : [halt, warn, skip, fallback] = halt.
      pick-tool>
      <pick-tool
          %name = hook:on-enter:typecheck.
          %on-failure : [halt, warn, skip, fallback] = halt.
      pick-tool>
      <pick-tool %name = github:post_review. pick-tool>
      <pick-tool %name = slack:notify_channel. pick-tool>
      <intercept
        %validate_in = none.
        %validate_out = none.
        %retry = 2.
        %structured_output = none.
        %output_schema = none.
        %fallback_model = none.
        %cache = off.
        %rate_limit = 1/min.
        %redact = [].
        %guard = none.
        %audit_log = true.
        %tool-order = [
          hook:on-enter:lint,
          hook:on-enter:typecheck,
          github:post_review,
          slack:notify_channel,
          hook:on-exit:typecheck,
          hook:on-exit:lint
        ].
      intercept>
      <drop-tool %name = hook:on-exit:typecheck. drop-tool>
      <drop-tool %name = hook:on-exit:lint. drop-tool>
    agent>
  post>

  <with
    <plugin %name = debug_trace. plugin>
    <plugin %name = timeout_budget. %max = 120s. plugin>
    <plugin %name = cost_ceiling. %max = $0.50. plugin>
  with>
pxml>
```


---

## 14. Open questions

### 14.1 Numeric terminator ambiguity

`%amount = 3.50.` — greedy parsing reads `3.50` then `.` terminator. Needs exhaustive edge case testing in nimble_parsec.

### 14.2 SpaceCowboy integration depth

SpaceCowboy as a Datastar-native Elixir server could accept inline PXML via Datastar forms, compile via AAA, and stream SSE events as agents execute. Integration depth is an open design question.

### 14.3 Command parameter syntax formalization

Commands currently use a mix of `key = value` pairs and positional content. The grammar for command parameters needs formalization: are they the same as block-mode `%` attributes (dot-terminated)? Or a lighter syntax (comma-separated, no dots)? Current examples use comma-separated without dots for readability, but this needs a definitive rule.

### 14.4 Conditional expression language

`/if @security_scan found = critical` — what is the expression grammar? Current assumption: `@agent_name property = value` for simple equality checks. More complex conditions (greater-than, contains, boolean combinators) would need an expression sublanguage. The minimal version (equality only) is safe and covers most guard-clause use cases. Inequality and `in` checks are the most likely extensions.

### 14.5 Alias scoping and resolution

`/alias` definitions are session-scoped by default. When nested inside `/remember`, they become cross-session. But what happens when a session alias and a remembered alias have the same name? Current assumption: session overrides remembered (closest scope wins). Needs explicit resolution rules.

### 14.6 AAA stage boundaries

The current design routes each command to exactly one AAA stage. But some commands might benefit from multi-stage processing. For example, `/agent @reviewer model = opus` is primarily Analyst work, but the Advocate might want to validate that the model choice aligns with the user's cost preferences. The boundary between "route to one stage" and "process across stages" needs clarification.


---

## 15. SOS Coding: Specification / Observation / Scenario

### 15.1 Problem statement

Agents working on a codebase can turn off tests, rewrite tests to pass trivially, or produce code that satisfies the letter of a test but not its intent. Traditional testing is endogenous — the tests live alongside the code, visible to the same agents that write the code. An agent optimizing for "tests pass" can game the tests instead of fixing the code.

SOS Coding solves this by introducing an **information boundary** between the agents doing the work and the criteria used to evaluate the work.

### 15.2 The three components

**Specification (Endogenous — visible to agents)**

The behavioral contract that describes what the system should do. Expressed as Gladius specs that define input→output relationships, invariants, and constraints. The Specification is visible to all working agents — they need it to know what to build.

A Specification is not a unit test. It's a declarative contract:

```
^auth_contract = schema(%{
  required(:endpoint) => string(:filled?),
  required(:method) => atom(in?: [:get, :post, :put, :delete]),
  required(:auth_state) => atom(in?: [:valid, :expired, :missing, :insufficient]),
  required(:expected_status) => integer(in?: [200, 401, 403, 404]),
  optional(:expected_body) => schema(%{
    optional(:redirect_url) => string(format: ~r/^https?:\/\//),
    optional(:error) => string(:filled?)
  })
})
```

The Specification can be auto-generated from codebases, documentation, language/library docs, or authored manually. It evolves with the codebase. Working agents read it, implement against it, and can even suggest changes to it — but they cannot modify it unilaterally.

**Observation (The Observer — sees everything)**

An external Observer agent that runs in a **separate Phlox graph** with its own shared store. The Observer has read access to:
- The Specification (via Gladius registry)
- The Scenarios (via the exogenous Scenario store)
- The codebase (via filesystem/git access)
- The working agents' execution trace (via event stream)

The Observer does NOT have:
- Write access to the working agents' shared store
- Ability to modify the working agents' pipeline
- Ability to inject prompts into working agents

The Observer's job is to evaluate whether the codebase, as modified by the working agents, satisfies both the Specification and the Scenarios. It issues Verdicts.

**Scenarios (Exogenous — invisible to agents)**

A Scenario is a natural-language behavioral test, written like a GWT (Given-When-Then) prompt for the Observer to interpret. Scenarios are the secret criteria — working agents never see them.

```
Given a user with an expired session token,
When they attempt to access /api/dashboard,
Then the system returns 401 with a JSON body containing a `redirect_url` field
pointing to the login page.
```

Key properties:
- **Exogenous to the system:** Stored in a separate, agent-inaccessible store
- **Immutable:** Once committed, agents cannot modify or delete them. Only humans or system administrators can retire scenarios.
- **Natural language:** The Observer (an LLM) evaluates whether behavior matches intent — not string matching
- **Dual origin:** Auto-generated by the Observer from the Specification, or manually authored by human participants
- **Attributable:** Each scenario tracks its author (`auto`, `@human_name`) for confidence weighting

### 15.3 Architecture

```
┌───────────────────────────────────────────────────────┐
│  Working Agent Graph (Phlox)                          │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐              │
│  │ Agent A  │→ │ Agent B  │→ │ Agent C  │              │
│  └─────────┘  └─────────┘  └─────────┘              │
│  Shared store: reads Specification (^spec)            │
│  CANNOT SEE: Scenarios                                │
│                                                       │
│  Events: AgentCompleted, ToolInvoked, TaskCompleted   │
└──────────────────────┬────────────────────────────────┘
                       │ event stream
                       ▼
┌───────────────────────────────────────────────────────┐
│  Observer Graph (separate Phlox instance)              │
│  ┌──────────────────────────────────────┐             │
│  │  Observer Extension                   │             │
│  │  Reads: Specification, Scenarios      │             │
│  │  Watches: codebase, event stream      │             │
│  │  Emits: Verdicts                      │             │
│  └──────────────────────────────────────┘             │
│  Shared store: Scenario store (exogenous)             │
│  CAN SEE: everything                                  │
└──────────────────────┬────────────────────────────────┘
                       │
                       ▼
┌───────────────────────────────────────────────────────┐
│  Verdict Store                                        │
│  ScenarioEvaluated events                             │
│  Per-scenario pass/fail/partial with reasoning        │
│  Aggregate scores per Specification                   │
│  Reward/penalty signals back to pipeline owner        │
└───────────────────────────────────────────────────────┘
```

The two Phlox graphs are architecturally separate. They share access to the codebase and the Specification (via Gladius registry), but only the Observer graph has access to the Scenario store. Communication is one-way: the Observer reads the working graph's event stream but cannot write to it.

### 15.4 Knowledge scoping

SOS introduces a new scoping primitive to PXML: **knowledge scoping** — declaring that certain information exists in the system but is invisible to specific agents.

This is distinct from existing scoping mechanisms:
- **Tool scoping** (`/pick-tool`, `/drop-tool`): controls what tools an agent can use
- **Data redaction** (`/redact`): strips sensitive fields from data before LLM calls
- **Knowledge scoping** (SOS): controls what information an agent can *know about*

The information boundary is enforced architecturally — the Scenario store is not in the working agents' shared store, not referenced in their prompts, and not accessible via any tool they have access to. The Observer runs in a separate process with its own memory. There is no mechanism by which a working agent can discover what scenarios exist.

### 15.5 Observer Extension

The Observer Extension is a Phlox Extension (persistent, cross-cutting) that implements the observation loop:

```elixir
defmodule SOS.ObserverExtension do
  @behaviour Phlox.Extension

  def on_install(graph) do
    # Subscribe to working graph's event stream
    # Load Specification from Gladius registry
    # Connect to Scenario store
  end

  def on_execution_complete(shared, trace) do
    # For each scenario in the store:
    #   1. Construct an evaluation prompt with:
    #      - The Specification (behavioral contract)
    #      - The Scenario (GWT natural language)
    #      - The relevant code changes (from trace)
    #      - The execution results (from trace)
    #   2. Ask the Observer LLM: does the code satisfy this scenario?
    #   3. Record a ScenarioEvaluated event with verdict + reasoning
    # Aggregate verdicts into an overall score
    # Emit ObservationCompleted event
  end
end
```

The Observer Extension uses its own LLM call to evaluate scenarios — this call is separate from the working agents' LLM calls. The Observer model can be a different model than the working agents (and should be, for independence).

### 15.6 Scenario store schema

Scenarios are stored in Postgres, separate from the PXML event store. The working agents' database connection has no access to this table.

```sql
CREATE TABLE sos_scenarios (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- What this scenario tests
    spec_ref        VARCHAR(200) NOT NULL,
    scope           VARCHAR(500),

    -- The scenario itself
    given_text      TEXT NOT NULL,
    when_text       TEXT NOT NULL,
    then_text       TEXT NOT NULL,
    full_text       TEXT GENERATED ALWAYS AS (
        'Given ' || given_text || E',\n' ||
        'When ' || when_text || E',\n' ||
        'Then ' || then_text || '.'
    ) STORED,

    -- Provenance
    authored_by     VARCHAR(200) NOT NULL,
    source          VARCHAR(20) NOT NULL
                    CHECK (source IN ('human', 'auto', 'system')),
    priority        VARCHAR(20) NOT NULL DEFAULT 'normal'
                    CHECK (priority IN ('critical', 'normal', 'low')),

    -- Lifecycle
    status          VARCHAR(20) NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'retired', 'superseded')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at      TIMESTAMPTZ,
    retired_by      VARCHAR(200),
    superseded_by   UUID REFERENCES sos_scenarios(id),

    -- Versioning
    version         INTEGER NOT NULL DEFAULT 1,
    parent_id       UUID REFERENCES sos_scenarios(id)
);

CREATE INDEX idx_sos_scenarios_spec ON sos_scenarios(spec_ref);
CREATE INDEX idx_sos_scenarios_status ON sos_scenarios(status) WHERE status = 'active';
CREATE INDEX idx_sos_scenarios_priority ON sos_scenarios(priority);
```

**Access control:** The Scenario store table is accessible only by the Observer Extension's database role. The working agents' Ecto repo does not have a connection to this schema. This is enforced at the Postgres role level, not at the application level — even if an agent somehow discovered the table name, it could not query it.

### 15.7 Verdict events

Verdicts are event-sourced alongside the rest of the PXML event store:

| Event | Key fields |
|-------|------------|
| `ScenarioCreated` | `scenario_id`, `spec_ref`, `given_text`, `when_text`, `then_text`, `authored_by`, `source`, `priority`, `created_at` |
| `ScenarioRetired` | `scenario_id`, `retired_by`, `reason`, `retired_at` |
| `ScenarioEvaluated` | `scenario_id`, `compilation_id`, `verdict` (pass/fail/partial), `confidence` (0.0-1.0), `reasoning` (Observer's explanation), `code_evidence` (relevant snippets), `evaluated_at` |
| `ObservationCompleted` | `compilation_id`, `spec_ref`, `total_scenarios`, `passed`, `failed`, `partial`, `aggregate_score`, `observer_model`, `completed_at` |
| `VerdictAppealed` | `scenario_id`, `compilation_id`, `appealed_by`, `appeal_reasoning`, `appealed_at` |
| `VerdictOverridden` | `scenario_id`, `compilation_id`, `overridden_by`, `new_verdict`, `override_reasoning`, `overridden_at` |

`VerdictAppealed` and `VerdictOverridden` enable human review of Observer decisions. A working agent or human can challenge a verdict — but the appeal is reviewed by a human, not by the working agents themselves.

### 15.8 Verdict projections

**ScenarioReport:** Per-Specification summary showing pass/fail rates, which scenarios are consistently failing, and trend over time.

**AgentTrustScore:** Per-agent trust metric built from verdict history. Agents that consistently produce code that passes scenarios build trust; agents that produce code requiring repeated revisions lose trust. This is the "reward/penalize" feedback loop.

**RegressionDetector:** Projects `ScenarioEvaluated` events over time to detect regressions — scenarios that previously passed but now fail after a change.

### 15.9 Auto-generation of scenarios

When `%auto_generate = true` in the `<sos>` block, the Observer reads the Specification and generates scenarios using its own LLM. Auto-generation targets:

1. **Happy path:** For each input→output pair in the spec, generate a scenario confirming the expected behavior
2. **Boundary conditions:** For each constraint (e.g., `gte?: 0`), generate scenarios at the boundary
3. **Error cases:** For each validation rule, generate a scenario with invalid input confirming the error response
4. **Invariant preservation:** For each invariant in the spec, generate a scenario that would violate it and confirm the system prevents the violation

Auto-generated scenarios are stored with `source = 'auto'` and can be weighted differently from human-authored scenarios in the aggregate score.

### 15.10 Integration with PXML commands

SOS integrates with existing PXML commands:

| Command | SOS integration |
|---------|----------------|
| `/observe` | Activates SOS for a scope |
| `/scenario` | Adds a scenario to the exogenous store |
| `/report on = @sos_observer` | Produces a human-readable verdict summary |
| `/validate target = output, against = ^spec` | The Interceptor validates within the pipeline; the Observer independently validates from outside |
| `/if @sos_observer score < 0.8 /abort/ if/` | Conditional on Observer's aggregate score |
| `/checkpoint after = @sos_observer, require = human_approval` | Pause for human review of verdicts |
| `/diff pxml:a pxml:b` | Can compare verdict results between compilations |

### 15.11 Example: full SOS pipeline

**Block mode:**

```
<pxml %ns = PXML:org:acme:auth-refactor.
  %version = 0.2.6.

  <sos
    %spec = ^auth_behavioral_contract.
    %scenarios = sos_store:auth_scenarios.
    %observer = @sos_observer.
    %auto_generate = true.
    %reward_strategy = partial.
    %on_failure = report.
  sos>

  <state
    %auth_code : ^auth_module_source.
    %test_results : ^test_output.
  state>

  <exec
    <agent %name = refactor_auth.
      %model = claude-opus.
      <system=
        You are an experienced Elixir developer refactoring
        an authentication module. Follow the specification
        provided in shared state.
      =system>
      <prompt=
        Refactor the auth module to support OAuth2 in addition
        to session-based auth. Maintain backward compatibility.
        The behavioral contract is in %auth_code.
      =prompt>
    agent>
  exec>

  <post
    <agent %name = run_tests.
      <pick-tool %name = shell:mix_test. pick-tool>
    agent>
  post>
pxml>
```

The working agents see the Specification (`^auth_behavioral_contract`) and implement against it. The Observer, running in its separate graph, reads the same Specification plus the 47 scenarios in `sos_store:auth_scenarios` — including 15 human-authored edge cases the agents have never seen. After the pipeline completes, the Observer evaluates each scenario against the refactored codebase and emits verdicts.

**Inline mode:**

```
/prompt
  Refactor the auth module to support OAuth2.
  /observe scope = lib/auth/, spec = ^auth_contract observe/
  /scenario for = ^auth_contract, priority = critical
    Given a user authenticating via OAuth2 with a valid Google token,
    When the token's email matches an existing account,
    Then the system links the OAuth2 identity and creates a session.
  scenario/
  /scenario for = ^auth_contract, priority = critical
    Given a user authenticating via OAuth2 with a revoked token,
    When the token validation fails,
    Then the system returns 401 without creating any session or account linkage.
  scenario/
prompt/
```

The human adds two critical scenarios inline. The Observer also auto-generates scenarios from the spec. The working agent never sees any of them.


---

## Appendix A: System defaults

When `<defaults>` is absent:

| Key | Default value |
|-----|---------------|
| `%model` | `claude-sonnet` |
| `%retry` | `2` |
| `%timeout` | `30s` |
| `%on-failure` | `warn` |
| `%structured_output` | `none` |
| `%output_schema` | `none` |
| `%tool-inheritance` | `inherit` |
| `%audit_log` | `false` |
| `%rate_limit` | `10/min` |
| `%cache` | `off` |
| `%redact` | `[]` |
| `%guard` | `none` |
| `%fallback_model` | `none` |


## Appendix B: Canonical interceptor pipeline

```
 1. Rate Limit          ← throttle
 2. Cache check         ← short-circuit if hit
 3. Redact              ← strip sensitive input
 4. Validate (in)       ← Gladius conform on input
 5. ── Node work ──     ← LLM call + tools (per %tool-order)
 6. Structured Output   ← parse LLM text → typed data
 7. Validate (out)      ← Gladius conform on output
 8. Guard               ← content safety
 9. Redact (restore)    ← re-hydrate sensitive fields
10. Cache store         ← memoize result

Retry wraps steps 3–9.
Fallback Model retries from step 5 with alternate model.
```


## Appendix C: Command quick reference

### By axis

| Axis | Commands | Count |
|------|----------|-------|
| Task framing | `/prompt` `/merge` `/goal` `/context` `/assume` `/constraint` `/ignore` `/scope` `/pin` `/include` `/repo` `/setup` `/use` `/prefer` | 14 |
| Thinking | `/think` `/selftalk` `/introspect` `/explain` `/reason` | 5 |
| Delegation | `/agent` `/model` `/pick-tool` `/drop-tool` `/delegate` `/as` `/task` `/message` | 8 |
| Communication | `/communication` `/format` `/tone` `/compact` `/compaction` `/verbose` `/ask` `/me` `/focus` | 9 |
| Protection | `/redact` `/cost` `/timeout` `/sandbox` `/audit` `/harness` `/customize` | 7 |
| Verification | `/critique` `/validate` `/test` `/dry-run` `/review` `/compare` `/diff` `/report` | 8 |
| Memory | `/session` `/remember` `/forget` `/recall` `/snapshot` `/replay` `/alias` | 7 |
| Flow control | `/plan` `/step` `/run` `/checkpoint` `/retry` `/abort` `/rollback` `/iterate` `/research` `/investigate` `/implement` `/if` `/unless` `/extend` `/without` `/notify` | 16 |
| Observation | `/observe` `/scenario` | 2 |
| **Total** | | **76** |

### By AAA stage

| Stage | Commands |
|-------|----------|
| Advocate (SLM) | `/prompt` `/merge` `/goal` `/me` `/ask` `/tone` `/recall` `/pin` `/prefer` |
| Analyst (MLM) | `/context` `/assume` `/constraint` `/ignore` `/scope` `/include` `/repo` `/setup` `/use` `/agent` `/model` `/pick-tool` `/drop-tool` `/validate` `/plan` `/redact` `/sandbox` `/extend` `/without` |
| Agent (LLM) | `/think` `/selftalk` `/introspect` `/explain` `/reason` `/delegate` `/as` `/task` `/message` `/communication` `/format` `/compact` `/verbose` `/focus` `/critique` `/test` `/review` `/compare` `/report` `/retry` `/iterate` `/research` `/investigate` `/implement` |
| System | `/compaction` `/cost` `/timeout` `/audit` `/harness` `/customize` `/dry-run` `/diff` `/session` `/remember` `/forget` `/snapshot` `/replay` `/alias` `/step` `/run` `/checkpoint` `/abort` `/rollback` `/notify` `/if` `/unless` `/observe` `/scenario` |

### By form

| Form | Commands |
|------|----------|
| Nests | `/prompt` `/merge` `/goal` `/context` `/assume` `/constraint` `/ignore` `/scope` `/pin` `/include` `/repo` `/setup` `/use` `/prefer` `/think` `/selftalk` `/introspect` `/explain` `/reason` `/agent` `/delegate` `/as` `/task` `/message` `/communication` `/format` `/compaction` `/ask` `/me` `/focus` `/redact` `/cost` `/sandbox` `/harness` `/customize` `/critique` `/validate` `/test` `/dry-run` `/review` `/compare` `/diff` `/report` `/session` `/remember` `/forget` `/recall` `/alias` `/plan` `/checkpoint` `/retry` `/iterate` `/research` `/investigate` `/implement` `/if` `/unless` `/extend` `/without` `/notify` `/observe` `/scenario` |
| Immediate | `/model` `/pick-tool` `/drop-tool` `/tone` `/compact` `/verbose` `/timeout` `/audit` `/snapshot` `/replay` `/step` `/run` `/abort` `/rollback` |


## Appendix D: Changelog

| Date | Version | Changes |
|------|---------|---------|
| 2026-04-07 | 0.1.0-draft | Initial draft. Sigil table, elements, inline/block modes. |
| 2026-04-07 | 0.2.0-draft | Streaming model. Defaults. Interceptor as Extension. Persistence. Bridge. |
| 2026-04-07 | 0.2.1-draft | Bulk flow model. CQRS/ES. Canonical interceptor pipeline. Capability element. |
| 2026-04-08 | 0.2.2-draft | AAA pipeline. 61-command vocabulary. Compilation receipts. Conditional guards. Composition commands. Backtick support. |
| 2026-04-08 | 0.2.2.1-draft | `/compaction` for state compression. `/validate` gains `target`. `/run` counterpart to `/step`. `/report` for post-mortems. `/extend` and `/without` gain structured parameters. 64 commands total. |
| 2026-04-09 | 0.2.3-draft | `/repo` and `/setup` for project scaffolding and preparation. `/use` for technology selection (directive). `/prefer` for ranked preferences (soft). Four levels of directiveness established: prefer → use → assume → constraint. `/communication` as full-featured verbosity/detail control; `/compact` and `/verbose` become documented shorthands. `/task` for named, trackable work units within agents with `TaskStarted`/`TaskCompleted`/`TaskFailed` events. 70 commands total. |
| 2026-04-09 | 0.2.4-draft | `/customize` for Phlox runtime configuration (concurrency, buffer, error_strategy, state_backend, checkpoint_strategy). `/harness` enhanced from stub to full harness selection/configuration/introspection (supports swappable harness implementations like Tao). `/message` for inter-pipeline A2A communication — the runtime companion to `<capability>`, with request-response, fire-and-forget, and broadcast patterns; Gladius validates contracts on both sides. `/notify` for event-driven notifications to external channels without pausing execution. `MessageSent`/`MessageReceived`/`MessageFailed`/`NotificationSent`/`RuntimeCustomized`/`HarnessConfigured` events added. 73 commands total. |
| 2026-04-09 | 0.2.4.1-draft | Protocol architecture documentation. ACP (IBM/BeeAI) merged into A2A (Google) under Linux Foundation in August 2025 — all ACP references updated to A2A. New section 3.5 documenting the two-layer protocol stack: A2A for agent↔agent communication (`/message`, `<capability>`), MCP for agent→tool invocation (`/pick-tool`, `/drop-tool`). `<capability>` gains `%agent_card` attribute for A2A Agent Card discovery. `/message` gains `protocol` parameter (default `a2a`). Legacy `ACP/1.0` protocol values accepted as `A2A/1.0`. 73 commands (no additions — documentation patch only). |
| 2026-04-09 | 0.2.5-draft | Pipeline phases renamed from `<pre>`/`<exec>`/`<post>` to `<prep>`/`<exec>`/`<post>` for alignment with PocketFlow naming. Section 6.4 expanded with full PocketFlow lifecycle documentation: per-node internal lifecycle (prep→exec→post with separation of concerns) vs. pipeline-level phases (groups of agents). `<system=>` + `<prompt=>` coexistence documented with realistic example in section 6.5 — system prompt defines agent persona (stable), task prompt defines per-run work (variable). `/merge` command added for multiplayer prompt synthesis — combines multiple `/prompt` blocks from different users into one compiled pipeline with strategies: synthesize, sequential, parallel, priority. `/prompt` gains `from` attribute for author identification in multiplayer contexts. `MergeCompiled` event added. 74 commands total. |
| 2026-04-09 | 0.2.6-draft | SOS Coding (Specification / Observation / Scenario) — new section 15 with full methodology. Solves agent test-gaming via information boundary: Specifications are endogenous (visible to agents), Scenarios are exogenous (invisible to agents), Observer watches from a separate Phlox graph. `<sos>` block element added (section 6.13) with `%spec`, `%scenarios`, `%observer`, `%auto_generate`, `%reward_strategy`, `%on_failure` attributes. `/observe` and `/scenario` commands added (Axis 9: Observation). Observer Extension architecture with separate Phlox graph, one-way event stream, Postgres-level access control on Scenario store. Knowledge scoping introduced as new primitive distinct from tool scoping and data redaction. Scenario store SQL schema with GWT structure, provenance tracking, immutability. Verdict event system: `ScenarioCreated`, `ScenarioRetired`, `ScenarioEvaluated`, `ObservationCompleted`, `VerdictAppealed`, `VerdictOverridden`. Verdict projections: ScenarioReport, AgentTrustScore, RegressionDetector. Auto-generation of scenarios from specs targeting happy path, boundary conditions, error cases, invariant preservation. Full SOS pipeline examples in both block and inline mode. `sos` package added to package topology. 76 commands total across 9 axes. |
