defmodule Phlox.Middleware.Simplect do
  @moduledoc """
  🪨 Middleware that simplects LLM output across an entire pipeline.

  Injects a token-compression system prompt into `shared` before each
  node runs, so any node that builds LLM messages from `shared` gets
  compressed output — without changing node code.

  Pair with `Phlox.Interceptor.Complect` for per-node overrides
  (change intensity or disable entirely on specific nodes).

  ## How it works

      Pipeline with Simplect middleware (:full)
      ─────────────────────────────────────────
      before_node: inject simplect prompt into shared[:system_prompt]
        │
        ├── FetchNode    → LLM responds terse   (inherits :full)
        ├── AnalyzeNode  → LLM responds ultra    (Complect overrides to :ultra)
        ├── SummarizeNode → LLM responds normal  (Complect overrides to :off)
        └── ClassifyNode → LLM responds terse    (inherits :full)

  ## Setup

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [Phlox.Middleware.Simplect],
        metadata: %{simplect: :full}
      )

  ## With FlowSupervisor

      Phlox.FlowSupervisor.start_flow(:my_job, flow, shared,
        middlewares: [Phlox.Middleware.Simplect, Phlox.Middleware.Checkpoint],
        metadata: %{simplect: :ultra}
      )

  ## Configuration

  The intensity level is resolved in this order:

  1. `shared[:simplect]` — per-flow override (e.g. set by a prior node)
  2. `metadata[:simplect]` in pipeline context — set at orchestration time
  3. Falls back to `:full`

  Supported levels: `:lite`, `:full`, `:ultra`.
  See `Phlox.Simplect` for what each level does.

  ## System prompt key

  By default, the simplect prompt is injected into `shared[:system_prompt]`.
  Override by setting `metadata[:simplect_key]`:

      metadata: %{simplect: :ultra, simplect_key: :llm_system}

  ## Disabling for the rest of the pipeline

  Set `shared[:simplect]` to `:off` in a node's `post/4` to skip
  injection for all subsequent nodes. For per-node control, use
  `Phlox.Interceptor.Complect` instead.
  """

  @behaviour Phlox.Middleware

  alias Phlox.Simplect

  @impl true
  def before_node(shared, ctx) do
    level = resolve_level(shared, ctx)

    case level do
      :off ->
        {:cont, shared}

      level ->
        key = Map.get(ctx.metadata, :simplect_key, :system_prompt)
        prompt = Simplect.prompt(level)

        updated =
          case Map.get(shared, key) do
            nil ->
              Map.put(shared, key, prompt)

            existing when is_binary(existing) ->
              if Simplect.marked?(existing) do
                # Replace existing simplect prompt (level may have changed)
                Map.put(shared, key, Simplect.replace(existing, level))
              else
                Map.put(shared, key, existing <> "\n\n" <> prompt)
              end
          end

        {:cont, updated}
    end
  end

  defp resolve_level(shared, ctx) do
    case Map.get(shared, :simplect) do
      nil ->
        Map.get(ctx.metadata, :simplect, :full)

      :off ->
        :off

      level when level in [:lite, :full, :ultra] ->
        level

      other ->
        raise ArgumentError,
              "Phlox.Middleware.Simplect: unknown level #{inspect(other)}. " <>
                "Expected :lite, :full, :ultra, or :off."
    end
  end
end
