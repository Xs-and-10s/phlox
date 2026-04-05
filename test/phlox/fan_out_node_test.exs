defmodule Phlox.FanOutNodeTest do
  use ExUnit.Case, async: true

  alias Phlox.Graph

  # ---------------------------------------------------------------------------
  # Sub-flow nodes
  # ---------------------------------------------------------------------------

  defmodule SquareNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.fetch!(shared, :item)
    def exec(n, _p), do: n * n
    def post(shared, _p, result, _p2), do: {:default, Map.put(shared, :squared, result)}
  end

  defmodule TagSubNode do
    use Phlox.Node
    def post(shared, _p, _e, params), do: {:default, Map.put(shared, :tagged, params.label)}
  end

  defmodule SlowSquareNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.fetch!(shared, :item)
    def exec(n, _p), do: (Process.sleep(20); n * n)
    def post(shared, _p, result, _p2), do: {:default, Map.put(shared, :squared, result)}
  end

  defmodule ExplodeSubNode do
    use Phlox.Node
    def exec(_p, _p2), do: raise "sub-flow boom"
  end

  # ---------------------------------------------------------------------------
  # Sub-flow builders
  # ---------------------------------------------------------------------------

  def square_flow do
    Graph.new()
    |> Graph.add_node(:square, SquareNode, %{})
    |> Graph.start_at(:square)
    |> Graph.to_flow!()
  end

  def slow_square_flow do
    Graph.new()
    |> Graph.add_node(:slow_square, SlowSquareNode, %{})
    |> Graph.start_at(:slow_square)
    |> Graph.to_flow!()
  end

  def explode_flow do
    Graph.new()
    |> Graph.add_node(:boom, ExplodeSubNode, %{}, max_retries: 1)
    |> Graph.start_at(:boom)
    |> Graph.to_flow!()
  end

  # ---------------------------------------------------------------------------
  # FanOutNode definitions
  # ---------------------------------------------------------------------------

  defmodule SquareFanOut do
    use Phlox.FanOutNode, parallel: false

    def fan_out_prep(shared, _p), do: Map.fetch!(shared, :numbers)
    def sub_flow(_p), do: Phlox.FanOutNodeTest.square_flow()

    def merge(shared, results, _p) do
      {:default, Map.put(shared, :squares, Enum.map(results, & &1.squared))}
    end
  end

  defmodule ParallelSquareFanOut do
    use Phlox.FanOutNode, parallel: true

    def fan_out_prep(shared, _p), do: Map.fetch!(shared, :numbers)
    def sub_flow(_p), do: Phlox.FanOutNodeTest.slow_square_flow()

    def merge(shared, results, _p) do
      {:default, Map.put(shared, :squares, Enum.map(results, & &1.squared))}
    end
  end

  defmodule CustomMappingFanOut do
    use Phlox.FanOutNode, parallel: false

    def fan_out_prep(shared, _p), do: Map.fetch!(shared, :items)

    # Custom item_to_shared: put :value and :index, keep parent :prefix
    def item_to_shared({idx, val}, parent_shared, _p) do
      Map.merge(parent_shared, %{item: val, index: idx})
    end

    def sub_flow(_p), do: Phlox.FanOutNodeTest.square_flow()

    def merge(shared, results, _p) do
      {:default, Map.put(shared, :results, results)}
    end
  end

  defmodule ExplodeFanOut do
    use Phlox.FanOutNode, parallel: false

    def fan_out_prep(shared, _p), do: Map.fetch!(shared, :numbers)
    def sub_flow(_p), do: Phlox.FanOutNodeTest.explode_flow()
    def merge(shared, results, _p), do: {:default, Map.put(shared, :results, results)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def build_flow(fan_node) do
    Graph.new()
    |> Graph.add_node(:fan, fan_node, %{})
    |> Graph.start_at(:fan)
    |> Graph.to_flow!()
  end

  # ---------------------------------------------------------------------------
  # Sequential fan-out
  # ---------------------------------------------------------------------------

  test "sequential fan-out squares each number" do
    flow = build_flow(SquareFanOut)
    assert {:ok, %{squares: [1, 4, 9, 16, 25]}} =
             Phlox.run(flow, %{numbers: [1, 2, 3, 4, 5]})
  end

  test "sequential fan-out with empty list returns empty results" do
    flow = build_flow(SquareFanOut)
    assert {:ok, %{squares: []}} = Phlox.run(flow, %{numbers: []})
  end

  test "sequential fan-out passes parent shared to item_to_shared" do
    flow = build_flow(SquareFanOut)
    # :extra_key should be visible in item_to_shared via parent_shared
    assert {:ok, result} = Phlox.run(flow, %{numbers: [3], extra_key: :present})
    assert result.squares == [9]
  end

  test "custom item_to_shared receives correct item and parent shared" do
    flow = build_flow(CustomMappingFanOut)
    items = [{0, 2}, {1, 3}, {2, 4}]
    {:ok, result} = Phlox.run(flow, %{items: items})
    # Each sub-flow saw :item from item_to_shared; squared it
    assert Enum.map(result.results, & &1.squared) == [4, 9, 16]
  end

  # ---------------------------------------------------------------------------
  # Parallel fan-out
  # ---------------------------------------------------------------------------

  test "parallel fan-out returns results in input order" do
    flow = build_flow(ParallelSquareFanOut)
    assert {:ok, %{squares: [1, 4, 9, 16, 25]}} =
             Phlox.run(flow, %{numbers: [1, 2, 3, 4, 5]})
  end

  test "parallel fan-out is faster than sequential for slow sub-flows" do
    # 5 items × 20ms sleep = 100ms sequential; parallel should be ~20ms
    flow_par = build_flow(ParallelSquareFanOut)

    t0 = System.monotonic_time(:millisecond)
    {:ok, _} = Phlox.run(flow_par, %{numbers: [1, 2, 3, 4, 5]})
    elapsed = System.monotonic_time(:millisecond) - t0

    # Should complete well under the sequential 100ms
    assert elapsed < 200, "Expected parallel to complete in <200ms, took #{elapsed}ms"
  end

  # ---------------------------------------------------------------------------
  # Error propagation
  # ---------------------------------------------------------------------------

  test "sub-flow exception propagates as flow error" do
    flow = build_flow(ExplodeFanOut)
    assert {:error, %RuntimeError{message: "sub-flow boom"}} =
             Phlox.run(flow, %{numbers: [1]})
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  test "default fan_out_prep returns empty list" do
    defmodule DefaultPrepFanOut do
      use Phlox.FanOutNode

      def sub_flow(_p), do: Phlox.FanOutNodeTest.square_flow()
    end

    flow = build_flow(DefaultPrepFanOut)
    # No :numbers key — uses default prep which returns []
    assert {:ok, %{fan_out_results: []}} = Phlox.run(flow, %{})
  end

  test "default merge puts results under :fan_out_results" do
    defmodule DefaultMergeFanOut do
      use Phlox.FanOutNode

      def fan_out_prep(shared, _p), do: Map.fetch!(shared, :numbers)
      def sub_flow(_p), do: Phlox.FanOutNodeTest.square_flow()
      # Not overriding merge — use default
    end

    flow = build_flow(DefaultMergeFanOut)
    {:ok, result} = Phlox.run(flow, %{numbers: [2, 3]})
    assert is_list(result.fan_out_results)
    assert length(result.fan_out_results) == 2
  end

  test "default item_to_shared puts item under :item key" do
    defmodule DefaultItemToSharedFanOut do
      use Phlox.FanOutNode

      def fan_out_prep(shared, _p), do: Map.fetch!(shared, :numbers)
      def sub_flow(_p), do: Phlox.FanOutNodeTest.square_flow()

      def merge(shared, results, _p) do
        {:default, Map.put(shared, :squares, Enum.map(results, & &1.squared))}
      end
    end

    flow = build_flow(DefaultItemToSharedFanOut)
    # SquareNode reads :item from shared — the default item_to_shared puts it there
    {:ok, result} = Phlox.run(flow, %{numbers: [4, 5]})
    assert result.squares == [16, 25]
  end
end
