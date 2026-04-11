defmodule Phlox.Property.CheckpointRoundTripTest do
  @moduledoc """
  Property-based test for Checkpoint.Memory round-trip integrity.

  Generates arbitrary shared maps and verifies that save → load_latest
  returns identical data. While the Memory adapter trivially preserves
  Elixir terms (it's backed by an Agent), this test:

  1. Documents the contract that all adapters must honour
  2. Catches regressions if serialization is ever added
  3. Exercises the Agent under concurrent writes
  4. Serves as a template for Ecto adapter PBTs (which serialize to JSON)
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Phlox.Checkpoint.Memory

  # ---------------------------------------------------------------------------
  # Generators — arbitrary shared maps with varied value types
  # ---------------------------------------------------------------------------

  # Leaf values that might appear in a shared map
  defp leaf_gen do
    one_of([
      integer(),
      float(),
      binary(),
      atom(:alphanumeric),
      boolean(),
      constant(nil)
    ])
  end

  # Recursive term generator — maps, lists, tuples, nested arbitrarily
  defp term_gen do
    tree(leaf_gen(), fn inner ->
      one_of([
        list_of(inner, max_length: 5),
        map_of(atom(:alphanumeric), inner, max_length: 5),
        tuple({inner, inner}),
        tuple({atom(:alphanumeric), inner, inner})
      ])
    end)
  end

  # A shared map with atom keys and arbitrary values
  defp shared_gen do
    map_of(atom(:alphanumeric), term_gen(), min_length: 1, max_length: 10)
  end

  # A valid checkpoint entry (mirrors what Middleware.Checkpoint produces)
  defp checkpoint_gen(shared) do
    %{
      run_id: "prop-test-#{System.unique_integer([:positive])}",
      sequence: 1,
      event_type: :node_completed,
      flow_name: "test_flow",
      node_id: :test_node,
      next_node_id: :next_node,
      action: :default,
      shared: shared,
      error_info: nil
    }
  end

  # ---------------------------------------------------------------------------
  # Setup — start/stop the Memory agent per test
  # ---------------------------------------------------------------------------

  setup do
    if Process.whereis(Phlox.Checkpoint.Memory) do
      try do Memory.stop() catch :exit, _ -> :ok end
    end
    {:ok, _pid} = Memory.start_link()
    on_exit(fn ->
      try do Memory.stop() catch :exit, _ -> :ok end
    end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "save then load_latest returns identical shared for arbitrary maps" do
    check all shared <- shared_gen(), max_runs: 200 do
      run_id = "roundtrip-#{System.unique_integer([:positive])}"
      checkpoint = checkpoint_gen(shared)

      :ok = Memory.save(run_id, checkpoint)
      {:ok, loaded} = Memory.load_latest(run_id)

      assert loaded.shared == shared,
        """
        Round-trip failed.
        Original: #{inspect(shared)}
        Loaded:   #{inspect(loaded.shared)}
        """
    end
  end

  property "load_latest returns the most recent save (last-write-wins)" do
    check all shared_list <- list_of(shared_gen(), min_length: 2, max_length: 5),
              max_runs: 100 do
      run_id = "latest-#{System.unique_integer([:positive])}"

      # Save all versions sequentially
      for {shared, idx} <- Enum.with_index(shared_list, 1) do
        checkpoint = %{checkpoint_gen(shared) | sequence: idx}
        :ok = Memory.save(run_id, checkpoint)
      end

      # load_latest must return the last one
      {:ok, loaded} = Memory.load_latest(run_id)
      expected = List.last(shared_list)
      assert loaded.shared == expected
    end
  end

  property "load_at retrieves checkpoint for specific node_id" do
    check all shared <- shared_gen(), max_runs: 100 do
      run_id = "load-at-#{System.unique_integer([:positive])}"
      node_id = :target_node

      checkpoint = %{checkpoint_gen(shared) | node_id: node_id, sequence: 1}
      :ok = Memory.save(run_id, checkpoint)

      # Save another checkpoint for a different node
      other = %{checkpoint_gen(%{decoy: true}) | node_id: :other_node, sequence: 2}
      :ok = Memory.save(run_id, other)

      {:ok, loaded} = Memory.load_at(run_id, node_id)
      assert loaded.shared == shared
      assert loaded.node_id == node_id
    end
  end

  property "delete removes all checkpoints for a run_id" do
    check all shared <- shared_gen(), max_runs: 100 do
      run_id = "delete-#{System.unique_integer([:positive])}"

      :ok = Memory.save(run_id, checkpoint_gen(shared))
      assert {:ok, _} = Memory.load_latest(run_id)

      :ok = Memory.delete(run_id)
      assert {:error, :not_found} = Memory.load_latest(run_id)
    end
  end

  property "next_sequence increments monotonically" do
    check all count <- integer(1..10), max_runs: 50 do
      run_id = "seq-#{System.unique_integer([:positive])}"

      for i <- 1..count do
        {:ok, seq} = Memory.next_sequence(run_id)
        assert seq == i

        checkpoint = %{checkpoint_gen(%{i: i}) | sequence: i}
        :ok = Memory.save(run_id, checkpoint)
      end
    end
  end

  property "concurrent saves to different run_ids don't interfere" do
    check all shared_pairs <- list_of(
                tuple({binary(min_length: 1), shared_gen()}),
                min_length: 2,
                max_length: 8
              ),
              max_runs: 50 do
      # Deduplicate run_ids
      pairs =
        shared_pairs
        |> Enum.with_index()
        |> Enum.map(fn {{_key, shared}, idx} ->
          {"concurrent-#{System.unique_integer([:positive])}-#{idx}", shared}
        end)

      # Save all concurrently
      tasks =
        for {run_id, shared} <- pairs do
          Task.async(fn ->
            :ok = Memory.save(run_id, checkpoint_gen(shared))
            {run_id, shared}
          end)
        end

      saved = Task.await_many(tasks, 5_000)

      # Each run_id must have exactly its own data
      for {run_id, expected_shared} <- saved do
        {:ok, loaded} = Memory.load_latest(run_id)
        assert loaded.shared == expected_shared,
          "run_id #{run_id} has wrong shared after concurrent writes"
      end
    end
  end
end
