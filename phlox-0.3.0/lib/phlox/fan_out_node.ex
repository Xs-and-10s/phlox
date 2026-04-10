defmodule Phlox.FanOutNode do
  @moduledoc """
  A node that fans out over a list, running a sub-flow for each item,
  then merges all results back into the parent `shared` map.

  This enables mid-flow parallelism without making the runner aware of
  fan-out — it's just a node whose `exec/2` happens to spawn sub-flows.

  ## Lifecycle

      fan_out_prep(shared, params)   → [item1, item2, ...]
          │
          │  for each item (serial or parallel):
          ▼
      item_to_shared(item, shared, params)  → item_shared
          │
          ▼
      Runner.orchestrate(sub_flow(params), item_shared)  → result_shared
          │
          ▼  collect all result_shared maps
      merge(shared, [result1, result2, ...], params)  → {action, new_shared}

  ## Usage

      defmodule MyApp.EmbedChunksNode do
        use Phlox.FanOutNode, parallel: true

        # Returns the list of items to process
        def fan_out_prep(shared, _params), do: shared.chunks

        # The sub-flow to run for each item
        def sub_flow(_params) do
          Phlox.Graph.new()
          |> Phlox.Graph.add_node(:embed, MyApp.EmbedNode, %{model: "ada-002"})
          |> Phlox.Graph.add_node(:store, MyApp.StoreNode, %{})
          |> Phlox.Graph.connect(:embed, :store)
          |> Phlox.Graph.start_at(:embed)
          |> Phlox.Graph.to_flow!()
        end

        # How to turn one item into a shared map for the sub-flow.
        # Default: %{item: item} merged onto parent shared.
        def item_to_shared(chunk, shared, _params) do
          Map.merge(shared, %{text: chunk.text, chunk_id: chunk.id})
        end

        # How to collect all sub-flow results back into parent shared.
        # results is a list of final shared maps, one per item.
        def merge(shared, results, _params) do
          embeddings = Enum.map(results, & &1.embedding)
          {:default, Map.put(shared, :embeddings, embeddings)}
        end
      end

  ## Options

  - `parallel: false` (default) — items run sequentially; each sub-flow's final
    `shared` is *not* passed to the next item (they all start from the same
    parent `shared`).
  - `parallel: true` — items run concurrently via `Task.async_stream`.
  - `max_concurrency:` — only used when `parallel: true`;
    defaults to `System.schedulers_online()`.
  - `timeout:` — per-task timeout in ms when `parallel: true`; default 30_000.

  ## Differences from `BatchNode`

  | | `BatchNode` | `FanOutNode` |
  |---|---|---|
  | Per-item work | Single `exec_one/2` call | Full sub-flow run |
  | Sub-flow access | ✗ | ✓ via `sub_flow/1` |
  | Item → shared mapping | Implicit | Explicit via `item_to_shared/3` |
  | Result merging | Automatic (list) | Custom via `merge/3` |
  """

  @callback fan_out_prep(shared :: map(), params :: map()) :: [term()]
  @callback sub_flow(params :: map()) :: Phlox.Flow.t()
  @callback item_to_shared(item :: term(), parent_shared :: map(), params :: map()) :: map()
  @callback merge(parent_shared :: map(), results :: [map()], params :: map()) ::
              {String.t() | :default, map()}

  defmacro __using__(opts) do
    parallel        = Keyword.get(opts, :parallel, false)
    max_concurrency = Keyword.get(opts, :max_concurrency, nil)
    timeout         = Keyword.get(opts, :timeout, 30_000)

    quote do
      @behaviour Phlox.FanOutNode
      @behaviour Phlox.Node

      @phlox_fo_parallel        unquote(parallel)
      @phlox_fo_max_concurrency unquote(max_concurrency)
      @phlox_fo_timeout         unquote(timeout)

      # ---------------------------------------------------------------------------
      # Overridable defaults
      # ---------------------------------------------------------------------------

      @impl Phlox.FanOutNode
      def fan_out_prep(_shared, _params), do: []

      # Default: put the item under :item, keeping rest of parent shared
      @impl Phlox.FanOutNode
      def item_to_shared(item, parent_shared, _params) do
        Map.put(parent_shared, :item, item)
      end

      # Default: collect all result shared maps into :fan_out_results
      @impl Phlox.FanOutNode
      def merge(shared, results, _params) do
        {:default, Map.put(shared, :fan_out_results, results)}
      end

      # ---------------------------------------------------------------------------
      # Phlox.Node implementation — generated, not meant to be overridden
      # ---------------------------------------------------------------------------

      # prep/2 bundles items + parent shared so exec/2 has everything it needs.
      # Users implement fan_out_prep/2 instead of prep/2.
      @impl Phlox.Node
      def prep(shared, params) do
        items = fan_out_prep(shared, params)
        {items, shared}
      end

      # exec/2 runs the sub-flow for each item, returns list of result shared maps
      @impl Phlox.Node
      def exec({items, parent_shared}, params) do
        flow = sub_flow(params)

        runner = fn item ->
          item_shared = item_to_shared(item, parent_shared, params)
          Phlox.Runner.orchestrate(flow, flow.start_id, item_shared)
        end

        if @phlox_fo_parallel do
          concurrency = @phlox_fo_max_concurrency || System.schedulers_online()

          items
          |> Task.async_stream(runner,
               max_concurrency: concurrency,
               timeout:         @phlox_fo_timeout,
               ordered:         true)
          |> Enum.map(fn {:ok, result} -> result end)
        else
          Enum.map(items, runner)
        end
      end

      @impl Phlox.Node
      def exec_fallback(_prep_res, exc, _params), do: raise(exc)

      # post/4 delegates to merge/3 — the user's result-collection logic
      @impl Phlox.Node
      def post(shared, _prep_res, results, params) do
        merge(shared, results, params)
      end

      defoverridable fan_out_prep: 2, item_to_shared: 3, merge: 3
    end
  end
end
