defmodule Phlox.Property.MonitorSnapshotTest do
  @moduledoc """
  Property-based test for Monitor snapshot state machine consistency.

  Generates random sequences of telemetry events (flow_start, node_start,
  node_stop, node_exception, flow_stop) and verifies that the ETS snapshot
  never enters an invalid state, regardless of event ordering.

  This catches:
  - Snapshot corruption from unexpected event ordering
  - Missing or stale fields after state transitions
  - shared drift (snapshot.shared doesn't match latest node_stop)
  - current_id inconsistencies
  - Crashes from out-of-order or duplicate events
  """

  # async: false — shared Monitor GenServer and ETS table
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Phlox.Monitor

  @table :phlox_monitor_snapshots

  # ---------------------------------------------------------------------------
  # Telemetry event emitters (bypass :telemetry, cast directly to Monitor)
  # ---------------------------------------------------------------------------

  defp emit(event, measurements, metadata) do
    Monitor.handle_telemetry_event(event, measurements, metadata, nil)
    # Cast is async — give the GenServer time to process
    Process.sleep(5)
  end

  defp emit_flow_start(flow_id, start_id) do
    emit([:phlox, :flow, :start],
      %{system_time: System.system_time()},
      %{flow_id: flow_id, start_id: start_id})
  end

  defp emit_node_start(flow_id, node_id) do
    emit([:phlox, :node, :start],
      %{system_time: System.system_time()},
      %{flow_id: flow_id, node_id: node_id, module: StubNode})
  end

  defp emit_node_stop(flow_id, node_id, shared) do
    emit([:phlox, :node, :stop],
      %{duration: System.convert_time_unit(50, :millisecond, :native)},
      %{flow_id: flow_id, node_id: node_id, module: StubNode,
        action: :default, shared: shared})
  end

  defp emit_node_exception(flow_id, node_id) do
    emit([:phlox, :node, :exception],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{flow_id: flow_id, node_id: node_id, module: StubNode,
        kind: :error, reason: %RuntimeError{message: "boom"}})
  end

  defp emit_flow_stop(flow_id, status) do
    emit([:phlox, :flow, :stop],
      %{duration: System.convert_time_unit(100, :millisecond, :native)},
      %{flow_id: flow_id, status: status})
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  @node_ids [:a, :b, :c, :d, :e]

  defp node_id_gen, do: member_of(@node_ids)

  # A single event in a flow's lifecycle
  defp event_gen do
    one_of([
      constant(:node_start),
      constant(:node_stop),
      constant(:node_exception)
    ])
  end

  # A sequence of node-level events (flow_start/stop added by the test)
  defp event_sequence_gen do
    list_of(
      tuple({event_gen(), node_id_gen()}),
      min_length: 1,
      max_length: 20
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_flow_id do
    "prop-monitor-#{System.unique_integer([:positive])}"
  end

  defp get_snapshot(flow_id) do
    case :ets.lookup(@table, flow_id) do
      [{^flow_id, snapshot, _expire}] -> snapshot
      [] -> nil
    end
  end

  # Clean up a specific flow from ETS after each property run
  defp cleanup(flow_id) do
    :ets.delete(@table, flow_id)
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "valid event sequences produce consistent snapshots" do
    check all events <- event_sequence_gen(),
              include_flow_stop <- boolean(),
              max_runs: 200 do
      flow_id = unique_flow_id()
      start_id = :a

      # Always begin with flow_start
      emit_flow_start(flow_id, start_id)

      snap = get_snapshot(flow_id)
      assert snap != nil, "Snapshot must exist after flow_start"
      assert snap.status == :running
      assert snap.flow_id == flow_id
      assert snap.start_id == start_id
      assert snap.current_id == start_id
      assert snap.shared == nil
      assert snap.nodes == %{}

      # Emit node events
      last_shared = Enum.reduce(events, nil, fn {event_type, node_id}, _last ->
        shared = %{node: node_id, ts: System.monotonic_time()}

        case event_type do
          :node_start ->
            emit_node_start(flow_id, node_id)
            nil

          :node_stop ->
            emit_node_stop(flow_id, node_id, shared)
            shared

          :node_exception ->
            emit_node_exception(flow_id, node_id)
            nil
        end
      end)

      # Check intermediate snapshot
      snap = get_snapshot(flow_id)
      assert snap.status == :running
      assert is_map(snap.nodes)

      # If the last event was a node_stop, shared should match
      if last_shared do
        assert snap.shared == last_shared
      end

      # Optionally end with flow_stop
      if include_flow_stop do
        emit_flow_stop(flow_id, :ok)

        snap = get_snapshot(flow_id)
        assert snap.status == :done
        assert snap.current_id == nil
      end

      cleanup(flow_id)
    end
  end

  property "node entries track status correctly after start/stop pairs" do
    check all node_ids <- list_of(node_id_gen(), min_length: 1, max_length: 8),
              max_runs: 200 do
      flow_id = unique_flow_id()
      emit_flow_start(flow_id, :a)

      for node_id <- node_ids do
        emit_node_start(flow_id, node_id)

        snap = get_snapshot(flow_id)
        node_entry = snap.nodes[node_id]
        assert node_entry != nil, "Node :#{node_id} must exist after node_start"
        assert node_entry.status == :running
        assert node_entry.started_at != nil
        assert node_entry.stopped_at == nil
        assert node_entry.duration_ms == nil

        emit_node_stop(flow_id, node_id, %{done: node_id})

        snap = get_snapshot(flow_id)
        node_entry = snap.nodes[node_id]
        assert node_entry.status == :done
        assert node_entry.stopped_at != nil
        assert node_entry.duration_ms != nil
        assert node_entry.duration_ms >= 0
      end

      cleanup(flow_id)
    end
  end

  property "node_exception sets error status on the node entry" do
    check all node_id <- node_id_gen(), max_runs: 50 do
      flow_id = unique_flow_id()
      emit_flow_start(flow_id, :a)
      emit_node_start(flow_id, node_id)
      emit_node_exception(flow_id, node_id)

      snap = get_snapshot(flow_id)
      node_entry = snap.nodes[node_id]
      assert match?({:error, _}, node_entry.status)
      assert node_entry.stopped_at != nil
      assert node_entry.duration_ms != nil

      cleanup(flow_id)
    end
  end

  property "flow_stop always sets current_id to nil" do
    check all status <- member_of([:ok, :error]),
              num_nodes <- integer(0..5),
              max_runs: 100 do
      flow_id = unique_flow_id()
      emit_flow_start(flow_id, :a)

      # Emit some node events
      for i <- 1..num_nodes//1 do
        nid = :"node_#{i}"
        emit_node_start(flow_id, nid)
        emit_node_stop(flow_id, nid, %{i: i})
      end

      emit_flow_stop(flow_id, status)

      snap = get_snapshot(flow_id)
      assert snap.current_id == nil
      assert snap.duration_ms != nil

      if status == :ok do
        assert snap.status == :done
      else
        assert snap.status == {:error, :see_node}
      end

      cleanup(flow_id)
    end
  end

  property "events without prior flow_start are silently ignored (no crash)" do
    check all events <- event_sequence_gen(), max_runs: 100 do
      flow_id = unique_flow_id()

      # Emit node events WITHOUT a flow_start — Monitor should not crash
      for {event_type, node_id} <- events do
        case event_type do
          :node_start -> emit_node_start(flow_id, node_id)
          :node_stop -> emit_node_stop(flow_id, node_id, %{orphan: true})
          :node_exception -> emit_node_exception(flow_id, node_id)
        end
      end

      # No snapshot should exist (flow_start never happened)
      assert get_snapshot(flow_id) == nil

      # Monitor is still alive
      assert Process.alive?(Process.whereis(Monitor))

      cleanup(flow_id)
    end
  end

  property "updated_at never goes backward" do
    check all events <- event_sequence_gen(), max_runs: 200 do
      flow_id = unique_flow_id()
      emit_flow_start(flow_id, :a)

      prev_updated = get_snapshot(flow_id).updated_at

      Enum.reduce(events, prev_updated, fn {event_type, node_id}, prev ->
        case event_type do
          :node_start -> emit_node_start(flow_id, node_id)
          :node_stop -> emit_node_stop(flow_id, node_id, %{})
          :node_exception -> emit_node_exception(flow_id, node_id)
        end

        snap = get_snapshot(flow_id)
        assert DateTime.compare(snap.updated_at, prev) in [:gt, :eq],
          "updated_at went backward: #{inspect(snap.updated_at)} < #{inspect(prev)}"
        snap.updated_at
      end)

      cleanup(flow_id)
    end
  end

  property "shared in snapshot matches the most recent node_stop" do
    check all stop_sequence <- list_of(
                tuple({node_id_gen(), binary(min_length: 1)}),
                min_length: 1, max_length: 10
              ),
              max_runs: 200 do
      flow_id = unique_flow_id()
      emit_flow_start(flow_id, :a)

      for {node_id, marker} <- stop_sequence do
        shared = %{marker: marker, node: node_id}
        emit_node_start(flow_id, node_id)
        emit_node_stop(flow_id, node_id, shared)

        snap = get_snapshot(flow_id)
        assert snap.shared == shared,
          "Snapshot shared should match last node_stop. " <>
          "Expected marker: #{inspect(marker)}, got: #{inspect(snap.shared)}"
      end

      cleanup(flow_id)
    end
  end

  property "duplicate flow_start overwrites the snapshot cleanly" do
    check all num_restarts <- integer(1..5), max_runs: 50 do
      flow_id = unique_flow_id()

      for i <- 1..num_restarts do
        start_id = :"start_#{i}"
        emit_flow_start(flow_id, start_id)

        snap = get_snapshot(flow_id)
        assert snap.status == :running
        assert snap.start_id == start_id
        assert snap.nodes == %{}
        assert snap.shared == nil
      end

      cleanup(flow_id)
    end
  end
end
