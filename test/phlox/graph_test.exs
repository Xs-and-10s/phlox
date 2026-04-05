defmodule Phlox.GraphTest do
  use ExUnit.Case, async: true

  alias Phlox.{Graph, Flow}

  # Minimal stub modules — graph builder only checks they're atoms, not that
  # they actually implement the behaviour (that's the runner's job at runtime).
  defmodule StubA, do: (use Phlox.Node)
  defmodule StubB, do: (use Phlox.Node)
  defmodule StubC, do: (use Phlox.Node)

  # ---------------------------------------------------------------------------
  # Graph.new/0
  # ---------------------------------------------------------------------------

  test "new/0 returns an empty builder" do
    b = Graph.new()
    assert b.nodes == %{}
    assert b.start_id == nil
  end

  # ---------------------------------------------------------------------------
  # Graph.add_node/5
  # ---------------------------------------------------------------------------

  test "add_node/4 inserts a node with defaults" do
    b = Graph.new() |> Graph.add_node(:a, StubA, %{foo: 1})

    assert %{id: :a, module: StubA, params: %{foo: 1},
             successors: %{}, max_retries: 1, wait_ms: 0} = b.nodes[:a]
  end

  test "add_node/5 accepts max_retries and wait_ms opts" do
    b = Graph.new() |> Graph.add_node(:a, StubA, %{}, max_retries: 5, wait_ms: 200)

    assert b.nodes[:a].max_retries == 5
    assert b.nodes[:a].wait_ms == 200
  end

  test "add_node overwrites an existing node with the same id" do
    b =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{v: 1})
      |> Graph.add_node(:a, StubB, %{v: 2})

    assert b.nodes[:a].module == StubB
    assert b.nodes[:a].params == %{v: 2}
  end

  test "multiple nodes are all stored" do
    b =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.add_node(:b, StubB, %{})
      |> Graph.add_node(:c, StubC, %{})

    assert map_size(b.nodes) == 3
  end

  # ---------------------------------------------------------------------------
  # Graph.connect/4
  # ---------------------------------------------------------------------------

  test "connect/3 adds a default successor" do
    b =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.add_node(:b, StubB, %{})
      |> Graph.connect(:a, :b)

    assert b.nodes[:a].successors == %{"default" => :b}
  end

  test "connect/4 adds a named-action successor" do
    b =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.add_node(:b, StubB, %{})
      |> Graph.connect(:a, :b, action: "ok")

    assert b.nodes[:a].successors == %{"ok" => :b}
  end

  test "a node can have multiple successors for different actions" do
    b =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.add_node(:b, StubB, %{})
      |> Graph.add_node(:c, StubC, %{})
      |> Graph.connect(:a, :b, action: "ok")
      |> Graph.connect(:a, :c, action: "error")

    assert b.nodes[:a].successors == %{"ok" => :b, "error" => :c}
  end

  test "connect emits a warning when overwriting an existing action" do
    import ExUnit.CaptureIO

    output =
      capture_io(:stderr, fn ->
        Graph.new()
        |> Graph.add_node(:a, StubA, %{})
        |> Graph.add_node(:b, StubB, %{})
        |> Graph.add_node(:c, StubC, %{})
        |> Graph.connect(:a, :b)
        |> Graph.connect(:a, :c)  # overwrites "default"
      end)

    assert output =~ "overwriting successor"
    assert output =~ "default"
    assert output =~ ":a"
  end

  # ---------------------------------------------------------------------------
  # Graph.start_at/2
  # ---------------------------------------------------------------------------

  test "start_at/2 sets the start_id" do
    b = Graph.new() |> Graph.add_node(:a, StubA, %{}) |> Graph.start_at(:a)
    assert b.start_id == :a
  end

  # ---------------------------------------------------------------------------
  # Graph.to_flow/1 — validation
  # ---------------------------------------------------------------------------

  test "to_flow/1 returns {:ok, %Flow{}} for a valid graph" do
    result =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.add_node(:b, StubB, %{})
      |> Graph.connect(:a, :b)
      |> Graph.start_at(:a)
      |> Graph.to_flow()

    assert {:ok, %Flow{start_id: :a}} = result
  end

  test "to_flow/1 returns {:error, _} when no start node is set" do
    {:error, reasons} =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.to_flow()

    assert Enum.any?(reasons, &(&1 =~ "No start node"))
  end

  test "to_flow/1 returns {:error, _} when start_id is not in the graph" do
    {:error, reasons} =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.start_at(:missing)
      |> Graph.to_flow()

    assert Enum.any?(reasons, &(&1 =~ ":missing"))
  end

  test "to_flow/1 returns {:error, _} for unknown successor references" do
    {:error, reasons} =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.connect(:a, :ghost)
      |> Graph.start_at(:a)
      |> Graph.to_flow()

    assert Enum.any?(reasons, &(&1 =~ ":ghost"))
  end

  test "to_flow/1 accumulates multiple validation errors" do
    {:error, reasons} =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.connect(:a, :ghost1)
      |> Graph.connect(:a, :ghost2, action: "err")
      # no start_at
      |> Graph.to_flow()

    assert length(reasons) == 3  # missing start + two bad successors
  end

  # ---------------------------------------------------------------------------
  # Graph.to_flow!/1
  # ---------------------------------------------------------------------------

  test "to_flow!/1 returns the flow directly for a valid graph" do
    flow =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{})
      |> Graph.start_at(:a)
      |> Graph.to_flow!()

    assert %Flow{start_id: :a} = flow
  end

  test "to_flow!/1 raises ArgumentError on invalid graph" do
    assert_raise ArgumentError, ~r/Invalid Phlox graph/, fn ->
      Graph.new() |> Graph.to_flow!()
    end
  end

  # ---------------------------------------------------------------------------
  # Flow struct shape
  # ---------------------------------------------------------------------------

  test "resulting Flow contains all nodes from the builder" do
    flow =
      Graph.new()
      |> Graph.add_node(:a, StubA, %{x: 1})
      |> Graph.add_node(:b, StubB, %{y: 2})
      |> Graph.connect(:a, :b)
      |> Graph.start_at(:a)
      |> Graph.to_flow!()

    assert Map.has_key?(flow.nodes, :a)
    assert Map.has_key?(flow.nodes, :b)
    assert flow.nodes[:a].params == %{x: 1}
    assert flow.nodes[:b].params == %{y: 2}
    assert flow.nodes[:a].successors == %{"default" => :b}
  end
end
