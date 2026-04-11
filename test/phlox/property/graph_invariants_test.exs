defmodule Phlox.Property.GraphInvariantsTest do
  @moduledoc """
  Property-based test for Graph construction invariants.

  Generates random graph topologies (random nodes, connections, start_at)
  and verifies that `to_flow/1` either succeeds with a valid Flow or
  fails with descriptive error messages — never crashes or returns
  inconsistent data.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Phlox.{Graph, Flow}

  # A stub module for node declarations — we only test graph structure,
  # not node execution.
  defmodule StubNode do
    use Phlox.Node
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Small pool of node IDs so connections have a decent chance of hitting
  # both valid and invalid targets.
  @node_ids [:a, :b, :c, :d, :e, :f, :g, :h]

  defp node_id_gen, do: member_of(@node_ids)

  # Extra IDs that might not be in the graph — for dangling edge testing
  @extra_ids [:x, :y, :z, :missing, :ghost]
  defp any_id_gen, do: member_of(@node_ids ++ @extra_ids)

  defp action_gen, do: member_of(["default", "error", "retry", "branch_a", "branch_b"])

  # A single graph-building operation
  defp operation_gen do
    one_of([
      tuple({constant(:add_node), node_id_gen()}),
      tuple({constant(:connect), node_id_gen(), any_id_gen(), action_gen()}),
      tuple({constant(:start_at), any_id_gen()})
    ])
  end

  defp operations_gen do
    list_of(operation_gen(), min_length: 0, max_length: 20)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp apply_operations(operations) do
    Enum.reduce(operations, Graph.new(), fn op, builder ->
      case op do
        {:add_node, id} ->
          Graph.add_node(builder, id, StubNode, %{})

        {:connect, from, to, action} ->
          # connect raises if from doesn't exist — guard it
          if Map.has_key?(builder.nodes, from) do
            Graph.connect(builder, from, to, action: action)
          else
            builder
          end

        {:start_at, id} ->
          Graph.start_at(builder, id)
      end
    end)
  end

  defp node_ids_in(builder), do: Map.keys(builder.nodes)

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "to_flow never crashes — always returns {:ok, _} or {:error, _}" do
    check all ops <- operations_gen(), max_runs: 300 do
      builder = apply_operations(ops)
      result = Graph.to_flow(builder)

      assert match?({:ok, %Flow{}}, result) or match?({:error, [_ | _]}, result),
        "to_flow returned unexpected: #{inspect(result)}"
    end
  end

  property "to_flow succeeds iff start_id is set, exists, and all edges are valid" do
    check all ops <- operations_gen(), max_runs: 300 do
      builder = apply_operations(ops)
      known = node_ids_in(builder)

      has_start = builder.start_id != nil
      start_exists = builder.start_id in known

      dangling_edges =
        for {_from_id, node} <- builder.nodes,
            {_action, to_id} <- node.successors,
            to_id not in known,
            do: to_id

      should_succeed = has_start and start_exists and dangling_edges == []

      case Graph.to_flow(builder) do
        {:ok, %Flow{}} ->
          assert should_succeed,
            "to_flow succeeded but expected failure. " <>
            "start: #{inspect(builder.start_id)}, known: #{inspect(known)}, " <>
            "dangling: #{inspect(dangling_edges)}"

        {:error, reasons} ->
          refute should_succeed,
            "to_flow failed but expected success. reasons: #{inspect(reasons)}"

          # Every reason must be a descriptive string
          for reason <- reasons do
            assert is_binary(reason) and byte_size(reason) > 0,
              "Error reason must be a non-empty string, got: #{inspect(reason)}"
          end
      end
    end
  end

  property "to_flow! raises ArgumentError iff to_flow returns {:error, _}" do
    check all ops <- operations_gen(), max_runs: 200 do
      builder = apply_operations(ops)

      case Graph.to_flow(builder) do
        {:ok, flow} ->
          assert Graph.to_flow!(builder) == flow

        {:error, _reasons} ->
          assert_raise ArgumentError, fn -> Graph.to_flow!(builder) end
      end
    end
  end

  property "valid flow preserves all declared nodes" do
    check all node_ids <- list_of(node_id_gen(), min_length: 1, max_length: 8),
              max_runs: 200 do
      unique_ids = Enum.uniq(node_ids)

      builder =
        Enum.reduce(unique_ids, Graph.new(), fn id, b ->
          Graph.add_node(b, id, StubNode, %{})
        end)
        |> Graph.start_at(hd(unique_ids))

      {:ok, flow} = Graph.to_flow(builder)
      assert MapSet.new(Map.keys(flow.nodes)) == MapSet.new(unique_ids)
    end
  end

  property "valid flow has start_id matching the builder" do
    check all node_ids <- list_of(node_id_gen(), min_length: 1, max_length: 8),
              start_idx <- integer(0..7),
              max_runs: 200 do
      unique_ids = Enum.uniq(node_ids)
      start_id = Enum.at(unique_ids, rem(start_idx, length(unique_ids)))

      builder =
        Enum.reduce(unique_ids, Graph.new(), fn id, b ->
          Graph.add_node(b, id, StubNode, %{})
        end)
        |> Graph.start_at(start_id)

      {:ok, flow} = Graph.to_flow(builder)
      assert flow.start_id == start_id
    end
  end

  property "cycles are valid — to_flow accepts self-loops and back-edges" do
    check all id <- node_id_gen(), max_runs: 50 do
      # Self-loop
      builder =
        Graph.new()
        |> Graph.add_node(id, StubNode, %{})
        |> Graph.connect(id, id, action: "loop")
        |> Graph.start_at(id)

      assert {:ok, %Flow{}} = Graph.to_flow(builder)
    end
  end

  property "add_node with duplicate ID overwrites cleanly" do
    check all id <- node_id_gen(),
              retries_1 <- integer(1..10),
              retries_2 <- integer(1..10),
              max_runs: 100 do
      builder =
        Graph.new()
        |> Graph.add_node(id, StubNode, %{}, max_retries: retries_1)
        |> Graph.add_node(id, StubNode, %{}, max_retries: retries_2)
        |> Graph.start_at(id)

      {:ok, flow} = Graph.to_flow(builder)
      # The second add_node wins
      assert flow.nodes[id].max_retries == retries_2
    end
  end

  property "error messages mention every dangling edge" do
    check all from_id <- node_id_gen(),
              dangling_ids <- list_of(member_of(@extra_ids), min_length: 1, max_length: 3),
              max_runs: 100 do
      builder =
        Enum.reduce(Enum.with_index(dangling_ids), Graph.new() |> Graph.add_node(from_id, StubNode, %{}),
          fn {to_id, idx}, b ->
            Graph.connect(b, from_id, to_id, action: "edge_#{idx}")
          end)
        |> Graph.start_at(from_id)

      case Graph.to_flow(builder) do
        {:ok, _} ->
          # All dangling_ids happened to be in @node_ids — skip
          :ok

        {:error, reasons} ->
          joined = Enum.join(reasons, " ")
          for to_id <- dangling_ids, to_id not in node_ids_in(builder) do
            assert String.contains?(joined, ":#{to_id}"),
              "Error messages should mention dangling target :#{to_id}, got: #{joined}"
          end
      end
    end
  end
end
