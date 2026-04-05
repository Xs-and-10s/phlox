defmodule Phlox.FlowServer do
  @moduledoc """
  An OTP `GenServer` wrapper around `Phlox.Runner`.

  Holds a `%Phlox.Flow{}` and the current `shared` state as GenServer state,
  enabling:

  - **Supervised execution** — run flows under a `Supervisor` or
    `DynamicSupervisor` for fault tolerance and restart strategies.
  - **Inspectable state** — query the current `shared` map at any point
    during a run (useful for LiveView dashboards or monitoring).
  - **Step-by-step execution** — advance one node at a time, letting callers
    observe intermediate state between steps.
  - **Full run** — run all nodes to completion in one `call`, blocking until
    done or an error occurs.

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
      %{shared: shared, current_id: id, status: status} = Phlox.FlowServer.state(pid)

      # Reset to re-run with the same or new shared
      :ok = Phlox.FlowServer.reset(pid, %{url: "https://other.com"})

  ## Status values

  - `:ready`    — not yet started
  - `:running`  — a `run/1` call is in progress (blocks the server)
  - `:stepping` — being advanced node-by-node via `step/1`
  - `:done`     — completed successfully; `shared` holds the final state
  - `{:error, exception}` — a node raised and all retries/fallbacks failed
  """

  use GenServer

  alias Phlox.Runner

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a FlowServer.

  ## Options

  - `flow:` (**required**) — a `%Phlox.Flow{}` struct
  - `shared:` (default `%{}`) — initial shared state
  - `name:` — optional GenServer name (atom, `{:global, name}`, or `{:via, ...}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, init_opts} = Keyword.split(opts, [:name])
    gen_opts = if name = Keyword.get(name_opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Run the flow to completion. Blocks until all nodes have executed."
  @spec run(GenServer.server()) :: {:ok, map()} | {:error, Exception.t()}
  def run(server), do: GenServer.call(server, :run, :infinity)

  @doc """
  Advance exactly one node. Returns:

  - `{:continue, next_node_id, current_shared}` — more nodes remain
  - `{:done, final_shared}` — the flow has finished
  - `{:error, exception}` — a node raised fatally
  """
  @spec step(GenServer.server()) :: {:continue, atom(), map()} | {:done, map()} | {:error, Exception.t()}
  def step(server), do: GenServer.call(server, :step, :infinity)

  @doc "Return the current server state snapshot."
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
    shared = Keyword.get(opts, :shared, %{})

    state = %{
      flow: flow,
      initial_shared: shared,
      shared: shared,
      current_id: flow.start_id,
      status: :ready
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:run, _from, %{status: status} = state)
      when status in [:done, :running] do
    {:reply, {:error, {:invalid_status, status}}, state}
  end

  def handle_call(:run, _from, state) do
    new_state = %{state | status: :running}

    result =
      try do
        final_shared = Runner.orchestrate(state.flow, state.current_id, state.shared)
        {:ok, final_shared}
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, final_shared} ->
        done_state = %{new_state | shared: final_shared, status: :done, current_id: nil}
        {:reply, {:ok, final_shared}, done_state}

      {:error, exc} ->
        error_state = %{new_state | status: {:error, exc}}
        {:reply, {:error, exc}, error_state}
    end
  end

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

    result =
      try do
        prep_res = node.module.prep(state.shared, params)
        exec_res = Phlox.Retry.run(node, prep_res)
        {action, new_shared} = node.module.post(state.shared, prep_res, exec_res, params)
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

  @impl GenServer
  def handle_call(:state, _from, state) do
    snapshot = %{
      shared: state.shared,
      current_id: state.current_id,
      status: state.status
    }

    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_call({:reset, new_shared}, _from, state) do
    shared = new_shared || state.initial_shared

    new_state = %{
      state
      | shared: shared,
        current_id: state.flow.start_id,
        status: :ready
    }

    {:reply, :ok, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_next(flow, node, action) do
    action_key = if action == :default, do: "default", else: action

    case Map.get(node.successors, action_key) do
      nil -> nil
      next_id -> Map.fetch!(flow.nodes, next_id)
    end
  end
end
