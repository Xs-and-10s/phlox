defmodule Phlox.Pipeline do
  @moduledoc """
  Orchestration loop with middleware and telemetry support.

  `Phlox.Pipeline` extends the pure `Phlox.Runner` loop with a
  composable middleware stack and `Phlox.Telemetry` event emission.
  Each node execution is wrapped by the configured middlewares in
  onion order:

      before_node (mw1 → mw2 → mw3)
        ↓
      prep → exec → post          ← actual node work
        ↓
      after_node  (mw3 → mw2 → mw1)

  If no middlewares are configured, node execution is identical to
  `Phlox.Runner.orchestrate/3`, but telemetry events still fire,
  enabling `Phlox.Monitor` to track progress.

  ## Telemetry

  Pipeline emits the full set of `Phlox.Telemetry` events:
  `[:phlox, :flow, :start]`, `[:phlox, :flow, :stop]`,
  `[:phlox, :node, :start]`, `[:phlox, :node, :stop]`, and
  `[:phlox, :node, :exception]`. See `Phlox.Telemetry` for the
  full event schema.

  ## Flow ID

  If `shared` does not contain a `:phlox_flow_id` key, Pipeline
  injects one using the `run_id`. This guarantees that
  `Phlox.Monitor.subscribe/1` always has a stable, discoverable ID
  to correlate events with.

  ## Usage

      Phlox.Pipeline.orchestrate(flow, flow.start_id, %{url: "..."},
        run_id: "my-run-001",
        middlewares: [MyApp.Middleware.Logger, Phlox.Middleware.Checkpoint],
        metadata: %{flow_name: "IngestPipeline"}
      )

  ## Resuming

  To resume from a specific node (e.g. after loading a checkpoint),
  pass that node's id as `start_id` and the checkpointed `shared`:

      Phlox.Pipeline.orchestrate(flow, :embed, checkpointed_shared,
        run_id: "my-run-001",
        middlewares: [Phlox.Middleware.Checkpoint],
        metadata: %{checkpoint: {Phlox.Checkpoint.Ecto, repo: MyRepo}}
      )

  ## Options

  - `middlewares:` — list of modules implementing `Phlox.Middleware`
  - `run_id:` — string identifier for this execution (auto-generated if omitted)
  - `metadata:` — arbitrary map threaded through middleware context
  - `on_node_done:` — optional `(node_id, shared) -> any()` callback invoked
    after each node completes (post-middleware, post-telemetry). Used by
    `FlowServer` to cast intermediate `shared` state back for real-time
    observability. Ignored if `nil`.
  """

  alias Phlox.{Flow, HaltedError, Retry, Telemetry}

  @doc """
  Orchestrate a flow with middleware support.

  Returns the final `shared` map. Raises `Phlox.HaltedError` if a
  middleware halts, or re-raises if a node raises after all retries.
  """
  @spec orchestrate(Flow.t(), atom(), map(), keyword()) :: map()
  def orchestrate(%Flow{} = flow, start_id, shared, opts \\ []) do
    middlewares = Keyword.get(opts, :middlewares, [])
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    metadata = Keyword.get(opts, :metadata, %{})

    # Guarantee :phlox_flow_id so telemetry/Monitor never uses make_ref()
    shared = Map.put_new(shared, :phlox_flow_id, run_id)
    flow_id = Telemetry.flow_id(shared)

    Telemetry.flow_start(flow_id, flow)
    start_time = System.monotonic_time()

    on_node_done = Keyword.get(opts, :on_node_done)
    node = fetch_node!(flow, start_id)

    try do
      result = step(flow, node, shared, middlewares, run_id, metadata, flow_id, on_node_done)
      duration = System.monotonic_time() - start_time
      Telemetry.flow_stop(flow_id, :ok, duration)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time
        Telemetry.flow_stop(flow_id, :error, duration)
        reraise e, __STACKTRACE__
    end
  end

  # ---------------------------------------------------------------------------
  # The loop
  # ---------------------------------------------------------------------------

  defp step(flow, node, shared, middlewares, run_id, metadata, flow_id, on_node_done) do
    ctx = %{
      node_id: node.id,
      node: node,
      flow: flow,
      run_id: run_id,
      metadata: metadata
    }

    # --- telemetry: node start ---
    Telemetry.node_start(flow_id, node)
    node_start_time = System.monotonic_time()

    # --- before hooks (list order) ---
    shared = run_before(middlewares, shared, ctx)

    # --- node execution (with interceptor support) ---
    {action, new_shared} =
      try do
        params = node.params
        prep_res = node.module.prep(shared, params)

        interceptors = Phlox.Interceptor.read_interceptors(node.module)
        exec_fn = Phlox.Interceptor.wrap(node.module, node.id, params, interceptors)
        exec_res = Retry.run(node, prep_res, exec_fn)

        node.module.post(shared, prep_res, exec_res, params)
      rescue
        e ->
          duration = System.monotonic_time() - node_start_time
          Telemetry.node_exception(flow_id, node, :error, e, duration)
          reraise e, __STACKTRACE__
      end

    # --- after hooks (reverse order) ---
    {new_shared, action} = run_after(Enum.reverse(middlewares), new_shared, action, ctx)

    # --- telemetry: node stop ---
    node_duration = System.monotonic_time() - node_start_time
    Telemetry.node_stop(flow_id, node, action, new_shared, node_duration)

    # --- notify caller of intermediate state ---
    if on_node_done, do: on_node_done.(node.id, new_shared)

    # --- resolve next node ---
    case resolve_next(flow, node, action) do
      nil -> new_shared
      next_node -> step(flow, next_node, new_shared, middlewares, run_id, metadata, flow_id, on_node_done)
    end
  end

  # ---------------------------------------------------------------------------
  # Middleware runners
  # ---------------------------------------------------------------------------

  defp run_before([], shared, _ctx), do: shared

  defp run_before([mw | rest], shared, ctx) do
    if has_callback?(mw, :before_node, 2) do
      case mw.before_node(shared, ctx) do
        {:cont, shared} ->
          run_before(rest, shared, ctx)

        {:halt, reason} ->
          raise HaltedError,
            reason: reason,
            node_id: ctx.node_id,
            middleware: mw,
            phase: :before_node
      end
    else
      run_before(rest, shared, ctx)
    end
  end

  defp run_after([], shared, action, _ctx), do: {shared, action}

  defp run_after([mw | rest], shared, action, ctx) do
    if has_callback?(mw, :after_node, 3) do
      case mw.after_node(shared, action, ctx) do
        {:cont, shared, action} ->
          run_after(rest, shared, action, ctx)

        {:halt, reason} ->
          raise HaltedError,
            reason: reason,
            node_id: ctx.node_id,
            middleware: mw,
            phase: :after_node
      end
    else
      run_after(rest, shared, action, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Graph traversal (same as Runner — Runner stays untouched)
  # ---------------------------------------------------------------------------

  defp resolve_next(flow, node, action) do
    action_key =
      case action do
        :default -> "default"
        str when is_binary(str) -> str
      end

    case Map.get(node.successors, action_key) do
      nil ->
        if map_size(node.successors) > 0 do
          IO.warn(
            "Phlox.Pipeline: flow ends — action '#{action_key}' not found in " <>
              "#{inspect(Map.keys(node.successors))} for node :#{node.id}",
            []
          )
        end

        nil

      next_id ->
        fetch_node!(flow, next_id)
    end
  end

  defp fetch_node!(%Flow{nodes: nodes}, id) do
    case Map.fetch(nodes, id) do
      {:ok, node} ->
        node

      :error ->
        raise ArgumentError,
              "Phlox.Pipeline: node :#{id} referenced but not found in graph. " <>
                "Known nodes: #{inspect(Map.keys(nodes))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp generate_run_id do
    # 16 random bytes → 128-bit hex string. No UUID dep needed.
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp has_callback?(module, function, arity) do
    # function_exported?/3 does NOT trigger module loading — a module
    # compiled to a BEAM file but not yet loaded returns false. We must
    # ensure it's loaded first.
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
