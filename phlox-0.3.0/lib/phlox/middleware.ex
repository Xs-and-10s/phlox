defmodule Phlox.Middleware do
  @moduledoc """
  A composable hook around each node's `prep → exec → post` cycle.

  Middlewares are applied in list order before a node runs, and in
  **reverse** list order after it completes (onion model — first in,
  last out). Each can inspect or transform `shared` state and routing
  actions at the boundary of every node.

  ## Implementing a middleware

      defmodule MyApp.Middleware.CostTracker do
        @behaviour Phlox.Middleware

        @impl true
        def before_node(shared, ctx) do
          {:cont, Map.put(shared, :_node_start, System.monotonic_time())}
        end

        @impl true
        def after_node(shared, action, ctx) do
          start = Map.get(shared, :_node_start, 0)
          elapsed = System.monotonic_time() - start
          costs = Map.update(shared, :_costs, [elapsed], &[elapsed | &1])
          {:cont, Map.delete(costs, :_node_start), action}
        end
      end

  ## Using middlewares

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [
          MyApp.Middleware.CostTracker,
          Phlox.Middleware.Checkpoint
        ]
      )

  ## Context

  Both callbacks receive a `context` map with:

  - `node_id`  — the atom id of the node about to run (or just ran)
  - `node`     — the full node struct from the flow
  - `flow`     — the `%Phlox.Flow{}` struct
  - `run_id`   — a string identifying this flow execution
  - `metadata` — arbitrary map passed through from the caller

  ## Halting

  Return `{:halt, reason}` from either callback to abort the flow
  immediately. The pipeline will raise `Phlox.HaltedError` with the
  reason and the node id where the halt occurred.

  This is useful for approval gates, budget limits, or circuit breakers.

  ## Optional callbacks

  Both `before_node/2` and `after_node/3` are optional. A middleware
  that only needs to act after each node can omit `before_node/2`
  entirely.
  """

  @typedoc """
  Context map provided to middleware callbacks.
  """
  @type context :: %{
          node_id: atom(),
          node: map(),
          flow: Phlox.Flow.t(),
          run_id: String.t(),
          metadata: map()
        }

  @doc """
  Called before a node's `prep → exec → post` cycle.

  Return `{:cont, shared}` to continue (optionally with a modified
  `shared`), or `{:halt, reason}` to abort the flow.
  """
  @callback before_node(shared :: map(), context()) ::
              {:cont, map()} | {:halt, term()}

  @doc """
  Called after a node's `post/4` returns.

  Receives the updated `shared` and the `action` that `post/4` chose.
  Return `{:cont, shared, action}` to continue (optionally modifying
  either), or `{:halt, reason}` to abort.
  """
  @callback after_node(shared :: map(), action :: term(), context()) ::
              {:cont, map(), term()} | {:halt, term()}

  @optional_callbacks [before_node: 2, after_node: 3]
end
