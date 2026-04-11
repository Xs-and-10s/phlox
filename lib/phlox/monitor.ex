defmodule Phlox.Monitor do
  @moduledoc """
  A GenServer that tracks the state of running flows in real time.

  `Phlox.Monitor` attaches to `:telemetry` events emitted by `Phlox.Pipeline`
  and `Phlox.FlowServer`, maintaining a per-flow snapshot in ETS. Subscribers
  (LiveView processes, SSE handlers, tests) receive a message whenever
  a flow or node transitions.

  ## Architecture

  The Monitor is transport-agnostic — it has no dependency on Phoenix,
  LiveView, Datastar, or any HTTP framework. Both `Phlox.Adapter.Phoenix`
  and `Phlox.Adapter.Datastar` subscribe to the Monitor and translate
  its messages into their respective transports.

      Telemetry events
           │
           ▼
      Phlox.Monitor (GenServer + ETS)
           │  {:phlox_monitor, event, snapshot}
           ├──▶ subscribed LiveView process
           ├──▶ subscribed SSE handler process
           └──▶ subscribed test process

  ## Starting

  `Phlox.Monitor` is started automatically by `Phlox.Application`. You do
  not need to add it to your supervision tree.

  To start it manually (e.g. in a standalone script or test):

      {:ok, _pid} = Phlox.Monitor.start_link([])

  ## Subscribing

      # Calling process receives {:phlox_monitor, event, snapshot} messages
      :ok = Phlox.Monitor.subscribe(flow_id)

  ## Querying

      # Current snapshot for one flow
      snapshot = Phlox.Monitor.get("my-flow-id")

      # All tracked flows
      snapshots = Phlox.Monitor.list()

  ## Snapshot shape

      %{
        flow_id:     "my-flow-id",
        status:      :running,       # :ready | :running | :done | {:error, exc}
        start_id:    :fetch,
        current_id:  :embed,         # nil when done
        shared:      %{...},         # latest shared state (updated after each node)
        started_at:  ~U[...],
        updated_at:  ~U[...],
        nodes: %{
          fetch: %{
            status:     :done,
            started_at: ~U[...],
            stopped_at: ~U[...],
            duration_ms: 142
          },
          embed: %{
            status:     :running,
            started_at: ~U[...],
            stopped_at: nil,
            duration_ms: nil
          }
        }
      }

  ## TTL

  Snapshots are retained for `ttl_ms` milliseconds after a flow completes
  (default: 5 minutes). Configure via `start_link`:

      Phlox.Monitor.start_link(ttl_ms: :timer.minutes(30))

  ## Events delivered to subscribers

  - `:flow_started`   — flow began running
  - `:node_started`   — a node began its prep→exec→post cycle
  - `:node_done`      — a node completed successfully
  - `:node_error`     — a node raised after all retries
  - `:flow_done`      — flow completed successfully
  - `:flow_error`     — flow terminated with an error
  - `:flow_expired`   — snapshot removed from ETS after TTL
  """

  use GenServer

  require Logger

  @table      :phlox_monitor_snapshots
  @handler_id "phlox-monitor-telemetry-handler"

  @default_ttl_ms :timer.minutes(5)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the Monitor."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe the calling process to updates for `flow_id`.

  Messages have the shape `{:phlox_monitor, event, snapshot}` where:
  - `event` is one of the atoms listed in the moduledoc
  - `snapshot` is the map described in the moduledoc
  """
  @spec subscribe(term()) :: :ok
  def subscribe(flow_id) do
    GenServer.call(__MODULE__, {:subscribe, flow_id, self()})
  end

  @doc """
  Unsubscribe the calling process from `flow_id` updates.
  Subscriptions are also cleaned up automatically when the subscriber exits.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(flow_id) do
    GenServer.call(__MODULE__, {:unsubscribe, flow_id, self()})
  end

  @doc "Return the current snapshot for `flow_id`, or `nil` if not tracked."
  @spec get(term()) :: map() | nil
  def get(flow_id) do
    case :ets.lookup(@table, flow_id) do
      [{^flow_id, snapshot, _expire_at}] -> snapshot
      []                                  -> nil
    end
  end

  @doc "Return all current snapshots as a list."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, snapshot, _expire_at} -> snapshot end)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    # public so get/1 and list/0 can read without going through the GenServer
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    attach_telemetry()

    # Sweep expired snapshots every minute
    :timer.send_interval(:timer.minutes(1), :sweep)

    {:ok, %{ttl_ms: ttl_ms, subscribers: %{}}}
  end

  # --- telemetry dispatch (called from handle_info via cast) ---

  @impl GenServer
  def handle_cast({:telemetry, event, measurements, metadata}, state) do
    handle_telemetry(event, measurements, metadata, state)
    {:noreply, state}
  end

  # --- subscription management ---

  @impl GenServer
  def handle_call({:subscribe, flow_id, pid}, _from, state) do
    ref  = Process.monitor(pid)
    subs = Map.update(state.subscribers, flow_id, [{pid, ref}], &[{pid, ref} | &1])
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, flow_id, pid}, _from, state) do
    subs = remove_subscriber(state.subscribers, flow_id, pid)
    {:reply, :ok, %{state | subscribers: subs}}
  end

  # --- subscriber process down ---

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subs =
      Map.new(state.subscribers, fn {flow_id, list} ->
        {flow_id, Enum.reject(list, fn {p, r} -> p == pid and r == ref end)}
      end)

    {:noreply, %{state | subscribers: subs}}
  end

  # --- TTL sweep ---

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, _snap, expire_at} -> expire_at <= now end)

    for {flow_id, snapshot, _} <- expired do
      :ets.delete(@table, flow_id)
      broadcast(flow_id, :flow_expired, snapshot, state.subscribers)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    safely_detach_telemetry()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Telemetry handling
  # ---------------------------------------------------------------------------

  defp attach_telemetry do
    if function_exported?(:telemetry, :attach_many, 4) do
      :telemetry.attach_many(
        @handler_id,
        [
          [:phlox, :flow, :start],
          [:phlox, :flow, :stop],
          [:phlox, :node, :start],
          [:phlox, :node, :stop],
          [:phlox, :node, :exception]
        ],
        &__MODULE__.handle_telemetry_event/4,
        nil
      )
    else
      Logger.warning("Phlox.Monitor: :telemetry not available - flow monitoring disabled. Add telemetry ~> 1.0 to your deps.")
    end
  end

  # Public so :telemetry can call it as an MFA
  def handle_telemetry_event(event, measurements, metadata, _config) do
    # Route through the GenServer to keep ETS writes serialised.
    # Using cast (not call) so the telemetry handler never blocks the emitting process.
    GenServer.cast(__MODULE__, {:telemetry, event, measurements, metadata})
  end

  defp handle_telemetry([:phlox, :flow, :start], _measurements, metadata, state) do
    flow_id  = metadata.flow_id
    now      = DateTime.utc_now()
    snapshot = %{
      flow_id:    flow_id,
      status:     :running,
      start_id:   metadata.start_id,
      current_id: metadata.start_id,
      shared:     nil,
      started_at: now,
      updated_at: now,
      nodes:      %{}
    }

    write_snapshot(flow_id, snapshot, :infinity, state.ttl_ms)
    broadcast(flow_id, :flow_started, snapshot, state.subscribers)
  end

  defp handle_telemetry([:phlox, :node, :start], _measurements, metadata, state) do
    flow_id = metadata.flow_id
    node_id = metadata.node_id
    now     = DateTime.utc_now()

    update_snapshot(flow_id, state.ttl_ms, fn snap ->
      node_entry = %{status: :running, started_at: now, stopped_at: nil, duration_ms: nil}

      %{snap |
        current_id: node_id,
        updated_at: now,
        nodes:      Map.put(snap.nodes, node_id, node_entry)
      }
    end)
    |> broadcast_if_ok(flow_id, :node_started, state.subscribers)
  end

  defp handle_telemetry([:phlox, :node, :stop], measurements, metadata, state) do
    flow_id    = metadata.flow_id
    node_id    = metadata.node_id
    duration   = System.convert_time_unit(measurements.duration, :native, :millisecond)
    now        = DateTime.utc_now()

    update_snapshot(flow_id, state.ttl_ms, fn snap ->
      node_entry = %{
        status:      :done,
        started_at:  get_in(snap, [:nodes, node_id, :started_at]),
        stopped_at:  now,
        duration_ms: duration
      }

      %{snap |
        updated_at: now,
        nodes: Map.put(snap.nodes, node_id, node_entry),
        shared: metadata[:shared]
      }
    end)
    |> broadcast_if_ok(flow_id, :node_done, state.subscribers)
  end

  defp handle_telemetry([:phlox, :node, :exception], measurements, metadata, state) do
    flow_id  = metadata.flow_id
    node_id  = metadata.node_id
    duration = System.convert_time_unit(measurements.duration, :native, :millisecond)
    now      = DateTime.utc_now()

    update_snapshot(flow_id, state.ttl_ms, fn snap ->
      node_entry = %{
        status:      {:error, metadata.reason},
        started_at:  get_in(snap, [:nodes, node_id, :started_at]),
        stopped_at:  now,
        duration_ms: duration
      }

      %{snap |
        updated_at: now,
        nodes:      Map.put(snap.nodes, node_id, node_entry)
      }
    end)
    |> broadcast_if_ok(flow_id, :node_error, state.subscribers)
  end

  defp handle_telemetry([:phlox, :flow, :stop], measurements, metadata, state) do
    flow_id  = metadata.flow_id
    status   = metadata.status
    duration = System.convert_time_unit(measurements.duration, :native, :millisecond)
    now      = DateTime.utc_now()
    event    = if status == :ok, do: :flow_done, else: :flow_error

    update_snapshot(flow_id, state.ttl_ms, fn snap ->
      snap
      |> Map.put(:status,      if(status == :ok, do: :done, else: {:error, :see_node}))
      |> Map.put(:current_id,  nil)
      |> Map.put(:updated_at,  now)
      |> Map.put(:duration_ms, duration)
    end)
    |> broadcast_if_ok(flow_id, event, state.subscribers)
  end

  # ---------------------------------------------------------------------------
  # ETS helpers
  # ---------------------------------------------------------------------------

  defp write_snapshot(flow_id, snapshot, :infinity, _ttl_ms) do
    :ets.insert(@table, {flow_id, snapshot, :infinity})
    snapshot
  end

  defp write_snapshot(flow_id, snapshot, expire_at, _ttl_ms) do
    :ets.insert(@table, {flow_id, snapshot, expire_at})
    snapshot
  end

  defp update_snapshot(flow_id, ttl_ms, fun) do
    case :ets.lookup(@table, flow_id) do
      [{^flow_id, snapshot, expire_at}] ->
        updated   = fun.(snapshot)
        new_expire = if expire_at == :infinity, do: :infinity, else: expire_ms(ttl_ms)
        :ets.insert(@table, {flow_id, updated, new_expire})
        {:ok, updated}

      [] ->
        # Flow started before Monitor was up, or flow_id is nil (FlowServer step mode)
        :error
    end
  end

  defp expire_ms(ttl_ms) do
    System.monotonic_time(:millisecond) + ttl_ms
  end

  defp broadcast_if_ok({:ok, snapshot}, flow_id, event, subscribers) do
    broadcast(flow_id, event, snapshot, subscribers)
  end
  defp broadcast_if_ok(:error, _flow_id, _event, _subscribers), do: :ok

  defp broadcast(flow_id, event, snapshot, subscribers) do
    for {pid, _ref} <- Map.get(subscribers, flow_id, []) do
      send(pid, {:phlox_monitor, event, snapshot})
    end
    :ok
  end

  defp remove_subscriber(subscribers, flow_id, pid) do
    Map.update(subscribers, flow_id, [], fn list ->
      Enum.reject(list, fn {p, _ref} -> p == pid end)
    end)
  end

  defp safely_detach_telemetry do
    if function_exported?(:telemetry, :detach, 1) do
      :telemetry.detach(@handler_id)
    end
  rescue
    _ -> :ok
  end
end
