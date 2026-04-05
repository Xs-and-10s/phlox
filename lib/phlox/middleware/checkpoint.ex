defmodule Phlox.Middleware.Checkpoint do
  @moduledoc """
  A `Phlox.Middleware` that persists flow state after each node completes.

  Appends a checkpoint entry via the configured `Phlox.Checkpoint` adapter
  after every node's `post/4` returns. This gives you resume, rewind, and
  a full audit trail of `shared` state transitions.

  ## Configuration

  The adapter is specified in the pipeline's `metadata` under the
  `:checkpoint` key as a `{module, opts}` tuple:

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        run_id: "ingest-2026-04-05",
        middlewares: [Phlox.Middleware.Checkpoint],
        metadata: %{
          checkpoint: {Phlox.Checkpoint.Memory, []},
          flow_name: "IngestPipeline"
        }
      )

  ## What gets saved

  After each node completes, a checkpoint entry is appended:

      %{
        run_id:       "ingest-2026-04-05",
        sequence:     3,                    # monotonic within run
        event_type:   :node_completed,      # or :flow_completed
        flow_name:    "IngestPipeline",
        node_id:      :embed,               # the node that just ran
        next_node_id: :store,               # where to resume (nil = done)
        action:       :default,             # action from post/4
        shared:       %{...},               # shared state at this point
        error_info:   nil
      }

  When a node completes and there is no next node (the flow is done),
  `event_type` is set to `:flow_completed` and `next_node_id` is `nil`.

  ## Resuming from a checkpoint

  Load the latest checkpoint and pass its `next_node_id` as the start
  node, with its `shared` as the initial state:

      {:ok, cp} = MyAdapter.load_latest("ingest-2026-04-05", opts)
      Phlox.Pipeline.orchestrate(flow, cp.next_node_id, cp.shared, ...)

  ## Middleware ordering

  Place `Checkpoint` **last** in the middleware list (or close to last)
  so that other middlewares' `after_node` modifications to `shared` are
  captured in the checkpoint. Remember: `after_node` runs in reverse
  list order, so the last middleware in the list runs first after the
  node completes.

      middlewares: [
        MyApp.Middleware.CostTracker,    # after_node runs second
        Phlox.Middleware.Checkpoint      # after_node runs first (captures costs)
      ]
  """

  @behaviour Phlox.Middleware

  @impl Phlox.Middleware
  def after_node(shared, action, ctx) do
    {adapter, adapter_opts} = fetch_adapter!(ctx)

    {:ok, sequence} = adapter.next_sequence(ctx.run_id, adapter_opts)

    next_node_id = resolve_next_node_id(ctx.flow, ctx.node, action)

    event_type =
      if next_node_id == nil, do: :flow_completed, else: :node_completed

    checkpoint = %{
      run_id: ctx.run_id,
      sequence: sequence,
      event_type: event_type,
      flow_name: Map.get(ctx.metadata, :flow_name),
      node_id: ctx.node_id,
      next_node_id: next_node_id,
      action: action,
      shared: shared,
      error_info: nil
    }

    case adapter.save(ctx.run_id, checkpoint, adapter_opts) do
      :ok ->
        {:cont, shared, action}

      {:error, reason} ->
        {:halt, {:checkpoint_save_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_adapter!(ctx) do
    case Map.get(ctx.metadata, :checkpoint) do
      {adapter, opts} when is_atom(adapter) and is_list(opts) ->
        {adapter, opts}

      nil ->
        raise ArgumentError,
              "Phlox.Middleware.Checkpoint requires :checkpoint in pipeline metadata. " <>
                "Pass metadata: %{checkpoint: {Phlox.Checkpoint.Memory, []}} or similar."

      other ->
        raise ArgumentError,
              "Expected :checkpoint metadata to be {module, opts}, got: #{inspect(other)}"
    end
  end

  defp resolve_next_node_id(flow, node, action) do
    action_key =
      case action do
        :default -> "default"
        str when is_binary(str) -> str
      end

    case Map.get(node.successors, action_key) do
      nil -> nil
      next_id -> if Map.has_key?(flow.nodes, next_id), do: next_id, else: nil
    end
  end
end
