defmodule PhloxIntegrationTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Real node modules — no mocks, no stubs
  # ---------------------------------------------------------------------------

  defmodule DoubleNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.fetch!(shared, :value)
    def exec(value, _p), do: value * 2
    def post(shared, _prep, result, _p), do: {:default, Map.put(shared, :value, result)}
  end

  defmodule AddNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.fetch!(shared, :value)
    def exec(value, params), do: value + Map.get(params, :addend, 0)
    def post(shared, _prep, result, _p), do: {:default, Map.put(shared, :value, result)}
  end

  defmodule BranchNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.fetch!(shared, :value)
    def exec(value, _p), do: value
    def post(shared, _prep, value, _p) when value > 10, do: {"big", Map.put(shared, :size, :big)}
    def post(shared, _prep, _value, _p), do: {"small", Map.put(shared, :size, :small)}
  end

  defmodule TagNode do
    use Phlox.Node
    def post(shared, _prep, _exec, params) do
      tag = Map.fetch!(params, :tag)
      {:default, Map.put(shared, :tag, tag)}
    end
  end

  defmodule FlakeyNode do
    use Phlox.Node
    def exec(_prep, _p) do
      count = Process.get(:flakey_count, 0)
      Process.put(:flakey_count, count + 1)
      if count < 2, do: raise("not ready"), else: :ok
    end
    def post(shared, _prep, :ok, _p), do: {:default, Map.put(shared, :recovered, true)}
  end

  defmodule ExplodingNode do
    use Phlox.Node
    def exec(_prep, _p), do: raise(RuntimeError, "kaboom")
  end

  # ---------------------------------------------------------------------------
  # BatchNode
  # ---------------------------------------------------------------------------

  defmodule SquareBatch do
    use Phlox.BatchNode, parallel: false

    def prep(shared, _p), do: Map.fetch!(shared, :numbers)
    def exec_one(n, _p), do: n * n

    def post(shared, _prep, results, _p) do
      {:default, Map.put(shared, :squares, results)}
    end
  end

  defmodule ParallelSquareBatch do
    use Phlox.BatchNode, parallel: true

    def prep(shared, _p), do: Map.fetch!(shared, :numbers)
    def exec_one(n, _p), do: n * n
    def post(shared, _prep, results, _p), do: {:default, Map.put(shared, :squares, results)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_flow(setup_fn) do
    Phlox.Graph.new() |> setup_fn.() |> Phlox.Graph.to_flow!()
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "single node: doubles the value" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:double, DoubleNode, %{})
        |> Phlox.Graph.start_at(:double)
      end)

    assert {:ok, %{value: 10}} = Phlox.run(flow, %{value: 5})
  end

  test "linear chain: double then add" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:double, DoubleNode, %{})
        |> Phlox.Graph.add_node(:add, AddNode, %{addend: 3})
        |> Phlox.Graph.connect(:double, :add)
        |> Phlox.Graph.start_at(:double)
      end)

    # 5 * 2 = 10, 10 + 3 = 13
    assert {:ok, %{value: 13}} = Phlox.run(flow, %{value: 5})
  end

  test "branching: routes 'big' and 'small' to different tag nodes" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:branch, BranchNode, %{})
        |> Phlox.Graph.add_node(:big_tag, TagNode, %{tag: :big_result})
        |> Phlox.Graph.add_node(:small_tag, TagNode, %{tag: :small_result})
        |> Phlox.Graph.connect(:branch, :big_tag, action: "big")
        |> Phlox.Graph.connect(:branch, :small_tag, action: "small")
        |> Phlox.Graph.start_at(:branch)
      end)

    assert {:ok, %{size: :big, tag: :big_result}} = Phlox.run(flow, %{value: 99})
    assert {:ok, %{size: :small, tag: :small_result}} = Phlox.run(flow, %{value: 3})
  end

  test "retry: flakey node succeeds on 3rd attempt with max_retries: 3" do
    Process.put(:flakey_count, 0)

    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:flakey, FlakeyNode, %{}, max_retries: 3)
        |> Phlox.Graph.start_at(:flakey)
      end)

    assert {:ok, %{recovered: true}} = Phlox.run(flow, %{})
    assert Process.get(:flakey_count) == 3
  end

  test "retry exhausted: returns {:error, _} when all retries fail" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:boom, ExplodingNode, %{}, max_retries: 2)
        |> Phlox.Graph.start_at(:boom)
      end)

    assert {:error, %RuntimeError{message: "kaboom"}} = Phlox.run(flow, %{})
  end

  test "BatchNode (sequential): squares a list of numbers" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:square, SquareBatch, %{})
        |> Phlox.Graph.start_at(:square)
      end)

    assert {:ok, %{squares: [1, 4, 9, 16, 25]}} =
             Phlox.run(flow, %{numbers: [1, 2, 3, 4, 5]})
  end

  test "BatchNode (parallel): squares a list of numbers concurrently" do
    flow =
      build_flow(fn g ->
        g
        |> Phlox.Graph.add_node(:square, ParallelSquareBatch, %{})
        |> Phlox.Graph.start_at(:square)
      end)

    assert {:ok, %{squares: [1, 4, 9, 16, 25]}} =
             Phlox.run(flow, %{numbers: [1, 2, 3, 4, 5]})
  end

  test "graph validation: rejects missing start node" do
    result =
      Phlox.Graph.new()
      |> Phlox.Graph.add_node(:a, DoubleNode, %{})
      |> Phlox.Graph.to_flow()

    assert {:error, [msg]} = result
    assert msg =~ "No start node"
  end

  test "graph validation: rejects unknown successor reference" do
    result =
      Phlox.Graph.new()
      |> Phlox.Graph.add_node(:a, DoubleNode, %{})
      |> Phlox.Graph.connect(:a, :nonexistent)
      |> Phlox.Graph.start_at(:a)
      |> Phlox.Graph.to_flow()

    assert {:error, [msg]} = result
    assert msg =~ ":nonexistent"
  end
end
