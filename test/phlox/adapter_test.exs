defmodule Phlox.AdapterTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Phlox.Adapter.Datastar — pure logic tests
  # (SSE stream tests require Plug/Datastar SDK which aren't in sandbox deps)
  # ---------------------------------------------------------------------------

  describe "Phlox.Adapter.Datastar" do
    test "stream/2 raises a clear error when datastar SDK is not loaded" do
      # In the sandbox, Datastar.SSE is not loaded — verify the guard fires
      # with an actionable message rather than a cryptic UndefinedFunctionError
      assert_raise RuntimeError, ~r/datastar_ex SDK/, fn ->
        Phlox.Adapter.Datastar.stream(%{}, "test-flow")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phlox.Adapter.Phoenix — compile-time and runtime logic
  # (LiveView socket tests require phoenix_live_view which isn't in sandbox deps)
  # ---------------------------------------------------------------------------

  describe "Phlox.Adapter.Phoenix" do
    test "phlox_subscribe/2 returns socket unchanged when LiveView is not available" do
      # Without phoenix_live_view, phlox_subscribe is a no-op (returns socket as-is)
      fake_socket = %{assigns: %{}}
      result = Phlox.Adapter.Phoenix.phlox_subscribe(fake_socket, "test-flow")
      # Should return the socket without raising
      assert result == fake_socket
    end

    test "__apply_snapshot__ returns socket unchanged when LiveView is not available" do
      fake_socket = %{assigns: %{}}
      snapshot = %{
        status:     :done,
        current_id: nil,
        nodes:      %{fetch: %{status: :done, duration_ms: 50}},
        started_at: DateTime.utc_now()
      }
      result = Phlox.Adapter.Phoenix.__apply_snapshot__(fake_socket, snapshot)
      assert result == fake_socket
    end

    test "use Phlox.Adapter.Phoenix compiles without phoenix_live_view" do
      # If this module compiles, the conditional macro worked correctly
      defmodule TestPhoenixMixin do
        use Phlox.Adapter.Phoenix
      end

      assert Code.ensure_loaded?(TestPhoenixMixin)
    end
  end

  # ---------------------------------------------------------------------------
  # Phlox.Adapter.Datastar — internal formatting functions via Monitor snapshot
  # We test these indirectly through the Monitor's snapshot shape
  # ---------------------------------------------------------------------------

  describe "signal value formatting (via snapshot inspection)" do
    test "Monitor snapshot has string-convertible status and node fields" do
      # Verify snapshot shape is what the Datastar adapter expects
      flow_id = "adapter-test-#{System.unique_integer([:positive])}"

      # Simulate the events the adapter consumes
      Phlox.Monitor.handle_telemetry_event(
        [:phlox, :flow, :start],
        %{system_time: System.system_time()},
        %{flow_id: flow_id, start_id: :fetch},
        nil
      )
      Process.sleep(30)

      Phlox.Monitor.handle_telemetry_event(
        [:phlox, :node, :stop],
        %{duration: System.convert_time_unit(88, :millisecond, :native)},
        %{flow_id: flow_id, node_id: :fetch, module: Phlox.Node, action: :default},
        nil
      )
      Process.sleep(30)

      snapshot = Phlox.Monitor.get(flow_id)
      assert snapshot != nil

      # These are the fields the Datastar adapter reads to build signals
      assert is_atom(snapshot.status) or is_tuple(snapshot.status)
      assert is_map(snapshot.nodes)
      assert snapshot.nodes[:fetch].duration_ms == 88
      assert %DateTime{} = snapshot.started_at
    end
  end
end
