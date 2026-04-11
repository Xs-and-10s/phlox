defmodule Phlox.MonitorTest do
  # async: false — shared Monitor GenServer and ETS table
  use ExUnit.Case, async: false

  alias Phlox.Monitor

  # ---------------------------------------------------------------------------
  # Helpers — simulate telemetry events directly
  #
  # Phlox.Monitor.handle_telemetry_event/4 is public (required by :telemetry's
  # MFA callback convention). Calling it directly lets us test the Monitor's
  # state machine without needing :telemetry installed.
  # ---------------------------------------------------------------------------

  defp emit(event, measurements, metadata) do
    Monitor.handle_telemetry_event(event, measurements, metadata, nil)
    # handle_telemetry_event casts to the GenServer; give it a moment to process
    Process.sleep(30)
  end

  defp flow_start(flow_id, start_id \\ :fetch) do
    emit([:phlox, :flow, :start],
      %{system_time: System.system_time()},
      %{flow_id: flow_id, start_id: start_id})
  end

  defp node_start(flow_id, node_id, module \\ Phlox.Node) do
    emit([:phlox, :node, :start],
      %{system_time: System.system_time()},
      %{flow_id: flow_id, node_id: node_id, module: module})
  end

  defp node_stop(flow_id, node_id, action \\ :default, module \\ Phlox.Node) do
    emit([:phlox, :node, :stop],
      %{duration: System.convert_time_unit(50, :millisecond, :native)},
      %{flow_id: flow_id, node_id: node_id, module: module, action: action,
        shared: %{phlox_flow_id: flow_id}})
  end

  defp node_exception(flow_id, node_id, reason \\ "boom") do
    emit([:phlox, :node, :exception],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{flow_id: flow_id, node_id: node_id, module: Phlox.Node,
        kind: :error, reason: %RuntimeError{message: reason}})
  end

  defp flow_stop(flow_id, status) do
    emit([:phlox, :flow, :stop],
      %{duration: System.convert_time_unit(100, :millisecond, :native)},
      %{flow_id: flow_id, status: status})
  end

  defp unique_id, do: "test-flow-#{System.unique_integer([:positive])}"

  # Drain leftover monitor messages
  defp flush do
    receive do
      {:phlox_monitor, _, _} -> flush()
    after 0 -> :ok
    end
  end

  setup do
    flush()
    :ok
  end

  defp collect(timeout_ms \\ 200), do: do_collect([], timeout_ms)

  defp do_collect(acc, timeout_ms) do
    receive do
      {:phlox_monitor, event, snap} -> do_collect([{event, snap} | acc], timeout_ms)
    after timeout_ms -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # get/1 and list/0 — ETS reads
  # ---------------------------------------------------------------------------

  test "get/1 returns nil for unknown flow" do
    assert Monitor.get("no-such-flow-#{unique_id()}") == nil
  end

  test "get/1 returns snapshot after flow_start event" do
    flow_id = unique_id()
    flow_start(flow_id, :fetch)

    snap = Monitor.get(flow_id)
    assert snap != nil
    assert snap.flow_id   == flow_id
    assert snap.status    == :running
    assert snap.start_id  == :fetch
  end

  test "get/1 reflects node progress after node events" do
    flow_id = unique_id()
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)

    snap = Monitor.get(flow_id)
    assert snap.nodes[:fetch].status      == :done
    assert is_integer(snap.nodes[:fetch].duration_ms)
    assert snap.nodes[:fetch].duration_ms >= 0
  end

  test "get/1 shows :done status after flow_stop :ok" do
    flow_id = unique_id()
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)
    flow_stop(flow_id, :ok)

    snap = Monitor.get(flow_id)
    assert snap.status     == :done
    assert snap.current_id == nil
  end

  test "list/0 includes tracked flow" do
    flow_id = unique_id()
    flow_start(flow_id)

    ids = Monitor.list() |> Enum.map(& &1.flow_id)
    assert flow_id in ids
  end

  # ---------------------------------------------------------------------------
  # Snapshot shape
  # ---------------------------------------------------------------------------

  test "flow_start snapshot has all required keys" do
    flow_id = unique_id()
    flow_start(flow_id, :parse)

    snap = Monitor.get(flow_id)
    assert %{
      flow_id:    ^flow_id,
      status:     :running,
      start_id:   :parse,
      current_id: :parse,
      nodes:      %{},
      started_at: %DateTime{}
    } = snap
  end

  test "node_stop snapshot has started_at, stopped_at, duration_ms" do
    flow_id = unique_id()
    flow_start(flow_id)
    node_start(flow_id, :embed)
    node_stop(flow_id, :embed)

    snap = Monitor.get(flow_id)
    node = snap.nodes[:embed]

    assert node.status      == :done
    assert %DateTime{}       = node.started_at
    assert %DateTime{}       = node.stopped_at
    assert is_integer(node.duration_ms)
  end

  test "node_exception snapshot records error reason" do
    flow_id = unique_id()
    flow_start(flow_id)
    node_start(flow_id, :boom)
    node_exception(flow_id, :boom, "kaboom")

    snap = Monitor.get(flow_id)
    assert {:error, %RuntimeError{message: "kaboom"}} = snap.nodes[:boom].status
  end

  # ---------------------------------------------------------------------------
  # subscribe/1 — event delivery
  # ---------------------------------------------------------------------------

  test "subscribe/1 delivers :flow_started" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)

    assert_receive {:phlox_monitor, :flow_started, snap}, 500
    assert snap.flow_id == flow_id
  end

  test "subscribe/1 delivers :node_started" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :fetch)

    events = collect()
    types  = Enum.map(events, fn {t, _} -> t end)
    assert :node_started in types
  end

  test "subscribe/1 delivers :node_done" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)

    events = collect()
    types  = Enum.map(events, fn {t, _} -> t end)
    assert :node_done in types
  end

  test "subscribe/1 delivers :flow_done on success" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)
    flow_stop(flow_id, :ok)

    assert_receive {:phlox_monitor, :flow_done, _}, 500
  end

  test "subscribe/1 delivers :node_error and :flow_error on failure" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :boom)
    node_exception(flow_id, :boom)
    flow_stop(flow_id, :error)

    events = collect()
    types  = Enum.map(events, fn {t, _} -> t end)
    assert :node_error  in types
    assert :flow_error  in types
    refute :flow_done   in types
  end

  test "events arrive in causal order" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)
    flow_stop(flow_id, :ok)

    events = collect() |> Enum.map(fn {t, _} -> t end)
    assert events == [:flow_started, :node_started, :node_done, :flow_done]
  end

  test "snapshot delivered in event matches get/1" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :fetch)
    node_stop(flow_id, :fetch)
    flow_stop(flow_id, :ok)

    events = collect()
    {_, received_snap} = List.last(events)
    stored_snap        = Monitor.get(flow_id)

    assert received_snap == stored_snap
  end

  # ---------------------------------------------------------------------------
  # unsubscribe/1
  # ---------------------------------------------------------------------------

  test "unsubscribe/1 stops event delivery" do
    flow_id = unique_id()
    :ok = Monitor.subscribe(flow_id)
    :ok = Monitor.unsubscribe(flow_id)
    flow_start(flow_id)

    events = collect(100)
    assert events == []
  end

  # ---------------------------------------------------------------------------
  # Subscriber cleanup on exit
  # ---------------------------------------------------------------------------

  test "dead subscriber is cleaned up — no crash when sending to it" do
    flow_id = unique_id()
    parent  = self()

    sub = spawn(fn ->
      Monitor.subscribe(flow_id)
      send(parent, :subscribed)
      # exit immediately without unsubscribing
    end)

    assert_receive :subscribed, 500
    # Wait for the subscriber process to die
    ref = Process.monitor(sub)
    assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500

    # Emitting now should not crash the Monitor
    flow_start(flow_id)

    assert Process.alive?(Process.whereis(Monitor))
  end

  # ---------------------------------------------------------------------------
  # Multiple subscribers
  # ---------------------------------------------------------------------------

  test "two subscribers both receive the same event" do
    flow_id = unique_id()
    parent  = self()

    other = spawn(fn ->
      Monitor.subscribe(flow_id)
      receive do
        {:phlox_monitor, :flow_done, _} -> send(parent, :other_got_done)
      after 1000 -> send(parent, :other_timed_out)
      end
    end)

    :ok = Monitor.subscribe(flow_id)
    flow_start(flow_id)
    node_start(flow_id, :step)
    node_stop(flow_id, :step)
    flow_stop(flow_id, :ok)

    assert_receive {:phlox_monitor, :flow_done, _}, 500
    assert_receive :other_got_done, 500
    _ = other
  end

  # ---------------------------------------------------------------------------
  # Ignores unknown flow_id events (flow started before Monitor was up)
  # ---------------------------------------------------------------------------

  test "node events for untracked flow_id are silently ignored" do
    flow_id = unique_id()
    # Emit node events WITHOUT a preceding flow_start
    node_start(flow_id, :orphan)
    node_stop(flow_id, :orphan)

    # Should not crash; snapshot should not exist
    assert Monitor.get(flow_id) == nil
    assert Process.alive?(Process.whereis(Monitor))
  end
end
