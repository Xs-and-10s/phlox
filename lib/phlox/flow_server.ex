defmodule Phlox.FlowServer do
  @moduledoc """
  An OTP `GenServer` wrapper around `Phlox.Pipeline`.

  Holds a `%Phlox.Flow{}` and the current `shared` state as GenServer state,
  enabling:

  - **Supervised execution** — run flows under a `Supervisor` or
    `DynamicSupervisor` for fault tolerance and restart strategies.
  - **Non-blocking run** — `run/1` blocks the *caller* until the flow
    completes, but executes the pipeline in a separate process so the
    GenServer remains responsive to `state/1` queries throughout. This
    enables real-time monitoring via `Phlox.Monitor`, LiveView, and SSE.
  - **Intermediate state** — during a run, `state/1` returns the `shared`
    map as of the last completed node, not just the initial or final value.
    Each node completion casts updated `shared` back to the GenServer.
  - **Crash detection** — the orchestration process is monitored via
    `Process.monitor/1`. If it is killed (OOM, `:kill` signal, linked
    crash), FlowServer replies to the caller with an error, emits
    `[:phlox, :flow, :stop]` telemetry, and transitions to `{:error, _}`
    rather than hanging silently.
  - **Inspectable state** — query the current `shared` map at any point
    during a run (useful for LiveView dashboards or monitoring).
  - **Step-by-step execution** — advance one node at a time, letting callers
    observe intermediate state between steps.
  - **Middleware support** — pass `:middlewares` to enable checkpointing,
    cost tracking, and other composable hooks.
  - **Telemetry** — all executions emit `Phlox.Telemetry` events, enabling
    `Phlox.Monitor` to track flow progress in real time. This works
    regardless of whether middlewares are configured.
  - **Resume from checkpoint** — pass `:resume` to start from a previously
    saved checkpoint instead of the flow's `start_id`.

  ## Flow ID

  If `shared` does not contain a `:phlox_flow_id` key, FlowServer
  automatically injects one using the `run_id`. This guarantees that
  `Phlox.Monitor.subscribe/1` can always correlate events to a flow.
  You can set it explicitly for human-readable IDs:

      shared = %{phlox_flow_id: "import-job-42", url: "https://example.com"}

  Or discover the auto-generated one after startup:

      %{flow_id: fid} = Phlox.FlowServer.state(pid)
      Phlox.Monitor.subscribe(fid)

  ## Usage

      # Start under a supervisor (recommended)
      children = [
        {Phlox.FlowServer, flow: my_flow, shared: %{url: "https://example.com"}, name: MyServer}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # Or start directly
      {:ok, pid} = Phlox.FlowServer.start_link(flow: my_flow, shared: %{})

      # Run to completion
      {:ok, final_shared} = Phlox.FlowServer.run(pid)

      # Step through manually
      {:continue, :parse, shared}  = Phlox.FlowServer.step(pid)
      {:continue, :store, shared}  = Phlox.FlowServer.step(pid)
      {:done, final_shared}        = Phlox.FlowServer.step(pid)

      # Inspect state at any point
      %{shared: shared, current_id: id, status: status, flow_id: fid} =
        Phlox.FlowServer.state(pid)

      # Reset to re-run with the same or new shared
      :ok = Phlox.FlowServer.reset(pid, %{url: "https://other.com"})

  ## With middlewares and checkpointing

      {:ok, pid} = Phlox.FlowServer.start_link(
        flow: my_flow,
        shared: %{url: "..."},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "ingest-001",
        metadata: %{
          checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo},
          flow_name: "IngestPipeline"
        }
      )

  ## Resume from checkpoint

      {:ok, pid} = Phlox.FlowServer.start_link(
        flow: my_flow,
        resume: "ingest-001",
        checkpoint: {Phlox.Checkpoint.Memory, []}
      )

  ## Status values

  - `:ready`    — not yet started
  - `:running`  — a `run/1` call is in progress (server remains responsive to `state/1`)
  - `:stepping` — being advanced node-by-node via `step/1`
  - `:done`     — completed successfully; `shared` holds the final state
  - `{:error, exception}` — a node raised and all retries/fallbacks failed
  """

  use GenServer

  alias Phlox.{Pipeline, Telemetry}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a FlowServer.

  ## Options

  - `flow:` (**required**) — a `%Phlox.Flow{}` struct
  - `shared:` (default `%{}`) — initial shared state
  - `name:` — optional GenServer name (atom, `{:global, name}`, or `{:via, ...}`)
  - `middlewares:` — list of `Phlox.Middleware` modules (enables Pipeline mode)
  - `run_id:` — identifier for this flow execution (auto-generated if omitted)
  - `metadata:` — arbitrary map passed through middleware context
  - `resume:` — run_id string to resume from a checkpoint (requires `checkpoint:`)
  - `checkpoint:` — `{adapter, opts}` tuple for resume support
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, init_opts} = Keyword.split(opts, [:name])
    gen_opts = if name = Keyword.get(name_opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Run the flow to completion.

  Blocks the *caller* until all nodes have executed, but the GenServer
  itself remains responsive — `state/1` can be called from other processes
  during execution to observe intermediate `shared` state.

  Returns `{:ok, final_shared}` on success, `{:error, exception}` on
  failure (including if the orchestration process is killed).
  """
  @spec run(GenServer.server()) :: {:ok, map()} | {:error, Exception.t()}
  def run(server), do: GenServer.call(server, :run, :infinity)

  @doc """
  Advance exactly one node. Returns:

  - `{:continue, next_node_id, current_shared}` — more nodes remain
  - `{:done, final_shared}` — the flow has finished
  - `{:error, exception}` — a node raised fatally

  When middlewares are configured, `before_node` and `after_node` hooks
  fire for each step.
  """
  @spec step(GenServer.server()) :: {:continue, atom(), map()} | {:done, map()} | {:error, Exception.t()}
  def step(server), do: GenServer.call(server, :step, :infinity)

  @doc """
  Return the current server state snapshot.

  Safe to call at any time, including while a `run/1` is in progress.
  During execution, `shared` reflects the state as of the last completed
  node (not just the initial value), and `current_id` tracks which node
  the pipeline is currently working on.

  The returned map contains:

  - `shared` — current shared state (updated after each node during a run)
  - `current_id` — the next node to execute (`nil` when done)
  - `status` — `:ready` | `:running` | `:stepping` | `:done` | `{:error, exc}`
  - `run_id` — execution identifier
  - `flow_id` — the telemetry/Monitor flow ID (matches `shared[:phlox_flow_id]`)
  """
  @spec state(GenServer.server()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Reset the server to `:ready` with optionally new shared state.
  If `new_shared` is omitted, the flow restarts with the original shared map.
  """
  @spec reset(GenServer.server(), map()) :: :ok
  def reset(server, new_shared \\ nil), do: GenServer.call(server, {:reset, new_shared})

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    flow = Keyword.fetch!(opts, :flow)
    middlewares = Keyword.get(opts, :middlewares, [])
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    metadata = Keyword.get(opts, :metadata, %{})

    # Handle resume from checkpoint
    {shared, current_id} =
      case Keyword.get(opts, :resume) do
        nil ->
          shared = Keyword.get(opts, :shared, %{})
          {shared, flow.start_id}

        resume_run_id ->
          load_resume_checkpoint(resume_run_id, flow, opts)
      end

    # If checkpoint adapter is provided but not in metadata, inject it
    metadata =
      case Keyword.get(opts, :checkpoint) do
        nil -> metadata
        cp_config -> Map.put_new(metadata, :checkpoint, cp_config)
      end

    # Guarantee :phlox_flow_id is always in shared so telemetry/Monitor
    # never falls back to make_ref(). User-supplied value wins.
    shared = Map.put_new(shared, :phlox_flow_id, run_id)

    state = %{
      flow: flow,
      initial_shared: shared,
      shared: shared,
      current_id: current_id,
      status: :ready,
      caller: nil,
      run_ref: nil,
      middlewares: middlewares,
      run_id: run_id,
      metadata: metadata
    }

    {:ok, state}
  end

  # --- run ---

  @impl GenServer
  def handle_call(:run, _from, %{status: status} = state)
      when status in [:done, :running] do
    {:reply, {:error, {:invalid_status, status}}, state}
  end

  def handle_call(:run, from, state) do
    server = self()

    # Spawn orchestration off the GenServer process.
    # The callback casts intermediate shared state back so state/1 stays fresh.
    # On completion (or crash), casts the final result back so we can reply.
    pid = spawn(fn ->
      result =
        try do
          final_shared = orchestrate(state, server)
          {:ok, final_shared}
        rescue
          e -> {:error, e}
        end

      GenServer.cast(server, {:flow_complete, result})
    end)

    # Monitor the spawned process so we detect kills, OOMs, and other
    # exits that bypass the try/rescue (e.g. :kill signal, linked crash).
    ref = Process.monitor(pid)

    {:noreply, %{state | status: :running, caller: from, run_ref: ref}}
  end

  # --- step ---

  @impl GenServer
  def handle_call(:step, _from, %{status: :done} = state) do
    {:reply, {:done, state.shared}, state}
  end

  def handle_call(:step, _from, %{status: {:error, exc}} = state) do
    {:reply, {:error, exc}, state}
  end

  def handle_call(:step, _from, %{status: :running} = state) do
    {:reply, {:error, {:invalid_status, :running}}, state}
  end

  def handle_call(:step, _from, state) do
    node = Map.fetch!(state.flow.nodes, state.current_id)
    params = node.params

    ctx = %{
      node_id: node.id,
      node: node,
      flow: state.flow,
      run_id: state.run_id,
      metadata: state.metadata
    }

    result =
      try do
        # Before hooks
        shared = run_before(state.middlewares, state.shared, ctx)

        # Node execution (with interceptor support)
        prep_res = node.module.prep(shared, params)

        interceptors = Phlox.Interceptor.read_interceptors(node.module)
        exec_fn = Phlox.Interceptor.wrap(node.module, node.id, params, interceptors)
        exec_res = Phlox.Retry.run(node, prep_res, exec_fn)

        {action, new_shared} = node.module.post(shared, prep_res, exec_res, params)

        # After hooks (reverse order)
        {new_shared, action} = run_after(Enum.reverse(state.middlewares), new_shared, action, ctx)

        {:ok, action, new_shared}
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, action, new_shared} ->
        next_node = resolve_next(state.flow, node, action)

        if next_node do
          new_state = %{state | shared: new_shared, current_id: next_node.id, status: :stepping}
          {:reply, {:continue, next_node.id, new_shared}, new_state}
        else
          done_state = %{state | shared: new_shared, current_id: nil, status: :done}
          {:reply, {:done, new_shared}, done_state}
        end

      {:error, exc} ->
        error_state = %{state | status: {:error, exc}}
        {:reply, {:error, exc}, error_state}
    end
  end

  # --- state ---

  @impl GenServer
  def handle_call(:state, _from, state) do
    snapshot = %{
      shared: state.shared,
      current_id: state.current_id,
      status: state.status,
      run_id: state.run_id,
      flow_id: state.shared[:phlox_flow_id]
    }

    {:reply, snapshot, state}
  end

  # --- reset ---

  @impl GenServer
  def handle_call({:reset, new_shared}, _from, state) do
    shared = new_shared || state.initial_shared
    new_run_id = generate_run_id()
    shared = Map.put_new(shared, :phlox_flow_id, new_run_id)

    new_state = %{
      state
      | shared: shared,
        current_id: state.flow.start_id,
        status: :ready,
        caller: nil,
        run_ref: nil,
        run_id: new_run_id
    }

    {:reply, :ok, new_state}
  end

  # ---------------------------------------------------------------------------
  # Async run — casts from the spawned orchestration process
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_cast({:node_done, node_id, shared}, state) do
    {:noreply, %{state | shared: shared, current_id: node_id}}
  end

  def handle_cast({:flow_complete, {:ok, final_shared}}, state) do
    if state.run_ref, do: Process.demonitor(state.run_ref, [:flush])
    GenServer.reply(state.caller, {:ok, final_shared})
    {:noreply, %{state | shared: final_shared, status: :done, current_id: nil, caller: nil, run_ref: nil}}
  end

  def handle_cast({:flow_complete, {:error, exc}}, state) do
    if state.run_ref, do: Process.demonitor(state.run_ref, [:flush])
    GenServer.reply(state.caller, {:error, exc})
    {:noreply, %{state | status: {:error, exc}, caller: nil, run_ref: nil}}
  end

  # ---------------------------------------------------------------------------
  # Spawned orchestration process crashed (OOM, :kill, linked exit, etc.)
  # This fires only when the try/rescue inside spawn was bypassed entirely.
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run_ref: ref} = state)
      when reason != :normal do
    # Emit flow_stop telemetry so Monitor + subscribers see the failure
    flow_id = Telemetry.flow_id(state.shared)
    Telemetry.flow_stop(flow_id, :error, 0)

    exc = %RuntimeError{
      message: "Phlox.FlowServer: orchestration process crashed: #{inspect(reason)}"
    }

    GenServer.reply(state.caller, {:error, exc})
    {:noreply, %{state | status: {:error, exc}, caller: nil, run_ref: nil}}
  end

  # Normal DOWN (process exited after casting flow_complete) — already handled
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Always use Pipeline — even with no middlewares it emits telemetry.
  # Runner stays pure (no side effects) for direct library use.
  # When called from the async run path, `server` is the FlowServer pid
  # so we can cast intermediate state back for real-time observability.
  defp orchestrate(state, server) do
    on_node_done =
      if server do
        fn node_id, shared -> GenServer.cast(server, {:node_done, node_id, shared}) end
      end

    Pipeline.orchestrate(state.flow, state.current_id, state.shared,
      middlewares: state.middlewares,
      run_id: state.run_id,
      metadata: state.metadata,
      on_node_done: on_node_done
    )
  end

  # Middleware runners for step mode (same logic as Pipeline)

  defp run_before([], shared, _ctx), do: shared

  defp run_before([mw | rest], shared, ctx) do
    if has_callback?(mw, :before_node, 2) do
      case mw.before_node(shared, ctx) do
        {:cont, shared} ->
          run_before(rest, shared, ctx)

        {:halt, reason} ->
          raise Phlox.HaltedError,
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
          raise Phlox.HaltedError,
            reason: reason,
            node_id: ctx.node_id,
            middleware: mw,
            phase: :after_node
      end
    else
      run_after(rest, shared, action, ctx)
    end
  end

  defp has_callback?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp resolve_next(flow, node, action) do
    action_key = if action == :default, do: "default", else: action

    case Map.get(node.successors, action_key) do
      nil -> nil
      next_id -> Map.fetch!(flow.nodes, next_id)
    end
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp load_resume_checkpoint(resume_run_id, flow, opts) do
    {adapter, adapter_opts} =
      case Keyword.fetch(opts, :checkpoint) do
        {:ok, {a, o}} -> {a, o}
        _ -> raise ArgumentError,
               "Phlox.FlowServer :resume requires a :checkpoint option, e.g. " <>
                 "checkpoint: {Phlox.Checkpoint.Memory, []}"
      end

    case adapter.load_latest(resume_run_id, adapter_opts) do
      {:ok, %{next_node_id: nil}} ->
        raise ArgumentError,
              "Phlox.FlowServer: flow #{inspect(resume_run_id)} has already completed — nothing to resume"

      {:ok, %{next_node_id: next_id, shared: shared}} ->
        unless Map.has_key?(flow.nodes, next_id) do
          raise ArgumentError,
                "Phlox.FlowServer: checkpoint targets node :#{next_id} " <>
                  "but it doesn't exist in the flow. " <>
                  "Known nodes: #{inspect(Map.keys(flow.nodes))}"
        end

        {shared, next_id}

      {:error, :not_found} ->
        raise ArgumentError,
              "Phlox.FlowServer: no checkpoint found for run_id #{inspect(resume_run_id)}"

      {:error, reason} ->
        raise ArgumentError,
              "Phlox.FlowServer: failed to load checkpoint: #{inspect(reason)}"
    end
  end
end
