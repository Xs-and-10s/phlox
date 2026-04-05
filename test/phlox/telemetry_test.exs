defmodule Phlox.TelemetryTest do
  use ExUnit.Case, async: true

  alias Phlox.{Graph, Telemetry}

  # Defined at module level — defining inside a helper function causes
  # "redefining module" warnings each time the helper is called.
  defmodule TelPassthrough do
    use Phlox.Node
    def post(shared, _p, _e, _params), do: {:default, Map.put(shared, :ran, true)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stub_node(id \\ :stub) do
    %{id: id, module: Phlox.Node, params: %{}}
  end

  defp simple_flow do
    Graph.new()
    |> Graph.add_node(:pass, TelPassthrough, %{})
    |> Graph.start_at(:pass)
    |> Graph.to_flow!()
  end

  # ---------------------------------------------------------------------------
  # flow_id/1
  # ---------------------------------------------------------------------------

  test "flow_id/1 returns the :phlox_flow_id value when present" do
    shared = %{phlox_flow_id: "my-stable-id"}
    assert Telemetry.flow_id(shared) == "my-stable-id"
  end

  test "flow_id/1 accepts any term as the flow id" do
    assert Telemetry.flow_id(%{phlox_flow_id: :atom_id}) == :atom_id
    assert Telemetry.flow_id(%{phlox_flow_id: 42}) == 42
    assert Telemetry.flow_id(%{phlox_flow_id: {1, 2}}) == {1, 2}
  end

  test "flow_id/1 returns a unique reference when :phlox_flow_id is absent" do
    id1 = Telemetry.flow_id(%{})
    id2 = Telemetry.flow_id(%{})
    assert is_reference(id1)
    assert is_reference(id2)
    # Each call produces a distinct reference
    assert id1 != id2
  end

  test "flow_id/1 ignores other keys in shared" do
    id = Telemetry.flow_id(%{some: :other, keys: true})
    assert is_reference(id)
  end

  # ---------------------------------------------------------------------------
  # Emit functions are no-ops when :telemetry is absent — must not raise
  # ---------------------------------------------------------------------------

  test "node_start/2 does not raise" do
    assert Telemetry.node_start(make_ref(), stub_node()) == :ok
  end

  test "node_stop/4 does not raise" do
    assert Telemetry.node_stop(make_ref(), stub_node(), :default, 1000) == :ok
  end

  test "node_exception/5 does not raise" do
    exc = %RuntimeError{message: "boom"}
    assert Telemetry.node_exception(make_ref(), stub_node(), :error, exc, 500) == :ok
  end

  test "flow_start/2 does not raise" do
    flow = simple_flow()
    assert Telemetry.flow_start(make_ref(), flow) == :ok
  end

  test "flow_stop/3 does not raise for :ok status" do
    assert Telemetry.flow_stop(make_ref(), :ok, 9999) == :ok
  end

  test "flow_stop/3 does not raise for :error status" do
    assert Telemetry.flow_stop(make_ref(), :error, 100) == :ok
  end

  # ---------------------------------------------------------------------------
  # Flow.run/2 instruments correctly even without :telemetry installed
  # ---------------------------------------------------------------------------

  test "Flow.run/2 completes successfully when telemetry is not available" do
    flow = simple_flow()
    assert {:ok, %{ran: true}} = Phlox.Flow.run(flow, %{})
  end

  test "Flow.run/2 uses :phlox_flow_id from shared as the flow_id" do
    # We can't observe the telemetry event directly without :telemetry,
    # but we can verify the key passes through to shared unchanged.
    flow = simple_flow()
    shared = %{phlox_flow_id: "test-run-001"}
    assert {:ok, result} = Phlox.Flow.run(flow, shared)
    # The key should survive the run (nodes didn't remove it)
    assert result[:phlox_flow_id] == "test-run-001"
  end

  test "emit functions accept nil flow_id without raising" do
    # flow_id can be nil when called from FlowServer before run starts
    assert Telemetry.node_start(nil, stub_node()) == :ok
    assert Telemetry.node_stop(nil, stub_node(), "default", 0) == :ok
    assert Telemetry.flow_stop(nil, :ok, 0) == :ok
  end

  test "node emit functions work with string and atom action values" do
    node = stub_node(:my_node)
    assert Telemetry.node_stop(make_ref(), node, "error", 100) == :ok
    assert Telemetry.node_stop(make_ref(), node, :default, 100) == :ok
  end
end
