defmodule Phlox.Telemetry do
  @moduledoc ~S"""
  Telemetry instrumentation for Phlox.

  Phlox emits `telemetry` events at key points in node and flow execution.
  `:telemetry` is an optional dependency — if it is not in your dependency
  tree, event emission is a no-op and no code path changes.

  ## Events

  ### `[:phlox, :node, :start]`
  Emitted immediately before a node's `prep/2` is called.

      measurements: %{system_time: integer()}
      metadata:     %{flow_id: term(), node_id: atom(), module: module()}

  ### `[:phlox, :node, :stop]`
  Emitted after `post/4` returns successfully.

      measurements: %{duration: integer()}   # native time units
      metadata:     %{flow_id: term(), node_id: atom(), module: module(),
                      action: String.t() | :default}

  ### `[:phlox, :node, :exception]`
  Emitted when a node raises after all retries and fallback are exhausted.

      measurements: %{duration: integer()}
      metadata:     %{flow_id: term(), node_id: atom(), module: module(),
                      kind: :error | :exit | :throw, reason: term()}

  ### `[:phlox, :flow, :start]`
  Emitted when `Phlox.Flow.run/2` is called.

      measurements: %{system_time: integer()}
      metadata:     %{flow_id: term(), start_id: atom()}

  ### `[:phlox, :flow, :stop]`
  Emitted when a flow completes (all nodes finished).

      measurements: %{duration: integer()}
      metadata:     %{flow_id: term(), status: :ok | :error}

  ## Attaching handlers

      :telemetry.attach_many(
        "my-app-phlox-logger",
        [
          [:phlox, :node, :start],
          [:phlox, :node, :stop],
          [:phlox, :node, :exception],
          [:phlox, :flow, :start],
          [:phlox, :flow, :stop]
        ],
        &MyApp.PhloxLogger.handle_event/4,
        nil
      )

  ## `flow_id`

  By default `flow_id` is a random reference generated per `Flow.run/2` call,
  ensuring events from concurrent flows are distinguishable. Supply a stable,
  human-readable ID via the `:phlox_flow_id` key in `shared`:

      job_id = "import-job-" <> Integer.to_string(job.id)
      Phlox.Flow.run(flow, %{phlox_flow_id: job_id})
  """

  @telemetry_available Code.ensure_loaded?(:telemetry)

  # ---------------------------------------------------------------------------
  # Public emit functions — called by Runner, Flow, and FlowServer
  # ---------------------------------------------------------------------------

  @doc false
  def node_start(flow_id, node) do
    emit([:phlox, :node, :start], %{system_time: System.system_time()}, %{
      flow_id: flow_id,
      node_id: node.id,
      module:  node.module
    })
  end

  @doc false
  def node_stop(flow_id, node, action, duration) do
    emit([:phlox, :node, :stop], %{duration: duration}, %{
      flow_id: flow_id,
      node_id: node.id,
      module:  node.module,
      action:  action
    })
  end

  @doc false
  def node_exception(flow_id, node, kind, reason, duration) do
    emit([:phlox, :node, :exception], %{duration: duration}, %{
      flow_id: flow_id,
      node_id: node.id,
      module:  node.module,
      kind:    kind,
      reason:  reason
    })
  end

  @doc false
  def flow_start(flow_id, flow) do
    emit([:phlox, :flow, :start], %{system_time: System.system_time()}, %{
      flow_id:  flow_id,
      start_id: flow.start_id
    })
  end

  @doc false
  def flow_stop(flow_id, status, duration) do
    emit([:phlox, :flow, :stop], %{duration: duration}, %{
      flow_id: flow_id,
      status:  status
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Extract or generate a flow ID from the shared map.
  Looks for `:phlox_flow_id`; falls back to a unique `make_ref/0` reference.
  """
  @spec flow_id(map()) :: term()
  def flow_id(shared), do: Map.get(shared, :phlox_flow_id, make_ref())

  # ---------------------------------------------------------------------------
  # Private — compile-time branch: no runtime overhead when :telemetry absent
  # ---------------------------------------------------------------------------

  if @telemetry_available do
    defp emit(event, measurements, metadata) do
      :telemetry.execute(event, measurements, metadata)
    end
  else
    defp emit(_event, _measurements, _metadata), do: :ok
  end
end
