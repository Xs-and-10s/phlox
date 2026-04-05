defmodule Phlox.Checkpoint.MemoryTest do
  use ExUnit.Case, async: false

  alias Phlox.Checkpoint.Memory

  # async: false because Memory uses a named Agent

  setup do
    {:ok, _pid} = Memory.start_link()

    on_exit(fn ->
      try do
        Memory.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ===========================================================================
  # save + load_latest
  # ===========================================================================

  describe "save/3 and load_latest/2" do
    test "saves and retrieves a checkpoint" do
      checkpoint = build_checkpoint(run_id: "run-1", sequence: 1, node_id: :fetch)

      assert :ok = Memory.save("run-1", checkpoint)
      assert {:ok, loaded} = Memory.load_latest("run-1")

      assert loaded.run_id == "run-1"
      assert loaded.sequence == 1
      assert loaded.node_id == :fetch
      assert %DateTime{} = loaded.inserted_at
    end

    test "load_latest returns the highest sequence" do
      Memory.save("run-1", build_checkpoint(sequence: 1, node_id: :fetch))
      Memory.save("run-1", build_checkpoint(sequence: 2, node_id: :parse))
      Memory.save("run-1", build_checkpoint(sequence: 3, node_id: :store))

      {:ok, latest} = Memory.load_latest("run-1")
      assert latest.sequence == 3
      assert latest.node_id == :store
    end

    test "load_latest returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Memory.load_latest("nonexistent")
    end
  end

  # ===========================================================================
  # load_at (rewind)
  # ===========================================================================

  describe "load_at/3 (rewind)" do
    setup do
      Memory.save("run-1", build_checkpoint(sequence: 1, node_id: :fetch, next_node_id: :parse))
      Memory.save("run-1", build_checkpoint(sequence: 2, node_id: :parse, next_node_id: :embed))
      Memory.save("run-1", build_checkpoint(sequence: 3, node_id: :embed, next_node_id: :store))
      :ok
    end

    test "loads checkpoint by node_id" do
      {:ok, cp} = Memory.load_at("run-1", :parse)
      assert cp.node_id == :parse
      assert cp.sequence == 2
      assert cp.next_node_id == :embed
    end

    test "returns the latest match when a node appears multiple times" do
      # Simulate a loop — :fetch runs again at sequence 4
      Memory.save("run-1", build_checkpoint(sequence: 4, node_id: :fetch, next_node_id: :parse))

      {:ok, cp} = Memory.load_at("run-1", :fetch)
      assert cp.sequence == 4
    end

    test "returns specific sequence when requested" do
      Memory.save("run-1", build_checkpoint(sequence: 4, node_id: :fetch, next_node_id: :parse))

      {:ok, cp} = Memory.load_at("run-1", :fetch, sequence: 1)
      assert cp.sequence == 1
    end

    test "returns :not_found for unknown node_id" do
      assert {:error, :not_found} = Memory.load_at("run-1", :nonexistent)
    end

    test "returns :not_found for unknown run_id" do
      assert {:error, :not_found} = Memory.load_at("no-such-run", :fetch)
    end
  end

  # ===========================================================================
  # history
  # ===========================================================================

  describe "history/2" do
    test "returns all checkpoints in order" do
      Memory.save("run-1", build_checkpoint(sequence: 1, node_id: :a))
      Memory.save("run-1", build_checkpoint(sequence: 2, node_id: :b))
      Memory.save("run-1", build_checkpoint(sequence: 3, node_id: :c))

      {:ok, entries} = Memory.history("run-1")
      assert length(entries) == 3
      assert Enum.map(entries, & &1.node_id) == [:a, :b, :c]
      assert Enum.map(entries, & &1.sequence) == [1, 2, 3]
    end

    test "returns empty list for unknown run_id" do
      {:ok, entries} = Memory.history("nonexistent")
      assert entries == []
    end
  end

  # ===========================================================================
  # list_resumable
  # ===========================================================================

  describe "list_resumable/1" do
    test "returns runs whose latest checkpoint is :node_completed" do
      # run-1: still in progress
      Memory.save("run-1", build_checkpoint(
        run_id: "run-1", sequence: 1, event_type: :node_completed
      ))

      # run-2: completed
      Memory.save("run-2", build_checkpoint(
        run_id: "run-2", sequence: 1, event_type: :node_completed
      ))
      Memory.save("run-2", build_checkpoint(
        run_id: "run-2", sequence: 2, event_type: :flow_completed
      ))

      # run-3: errored
      Memory.save("run-3", build_checkpoint(
        run_id: "run-3", sequence: 1, event_type: :node_completed
      ))
      Memory.save("run-3", build_checkpoint(
        run_id: "run-3", sequence: 2, event_type: :flow_errored
      ))

      {:ok, resumable} = Memory.list_resumable()

      run_ids = Enum.map(resumable, & &1.run_id)
      assert "run-1" in run_ids
      refute "run-2" in run_ids
      refute "run-3" in run_ids
    end

    test "returns empty list when nothing is resumable" do
      Memory.save("run-1", build_checkpoint(event_type: :flow_completed))
      {:ok, resumable} = Memory.list_resumable()
      assert resumable == []
    end
  end

  # ===========================================================================
  # delete
  # ===========================================================================

  describe "delete/2" do
    test "removes all checkpoints for a run_id" do
      Memory.save("run-1", build_checkpoint(sequence: 1))
      Memory.save("run-1", build_checkpoint(sequence: 2))

      assert :ok = Memory.delete("run-1")
      assert {:error, :not_found} = Memory.load_latest("run-1")
    end

    test "doesn't affect other runs" do
      Memory.save("run-1", build_checkpoint(sequence: 1, run_id: "run-1"))
      Memory.save("run-2", build_checkpoint(sequence: 1, run_id: "run-2"))

      Memory.delete("run-1")
      assert {:ok, _} = Memory.load_latest("run-2")
    end

    test "deleting nonexistent run_id is a no-op" do
      assert :ok = Memory.delete("nonexistent")
    end
  end

  # ===========================================================================
  # next_sequence
  # ===========================================================================

  describe "next_sequence/2" do
    test "returns 1 for a new run" do
      assert {:ok, 1} = Memory.next_sequence("fresh-run")
    end

    test "returns count + 1 after saves" do
      Memory.save("run-1", build_checkpoint(sequence: 1))
      assert {:ok, 2} = Memory.next_sequence("run-1")

      Memory.save("run-1", build_checkpoint(sequence: 2))
      assert {:ok, 3} = Memory.next_sequence("run-1")
    end
  end

  # ===========================================================================
  # clear
  # ===========================================================================

  describe "clear/0" do
    test "removes all data from all runs" do
      Memory.save("run-1", build_checkpoint(sequence: 1, run_id: "run-1"))
      Memory.save("run-2", build_checkpoint(sequence: 1, run_id: "run-2"))

      Memory.clear()

      assert {:error, :not_found} = Memory.load_latest("run-1")
      assert {:error, :not_found} = Memory.load_latest("run-2")
    end
  end

  # ===========================================================================
  # checkpoint data integrity
  # ===========================================================================

  describe "data integrity" do
    test "shared map round-trips with all Elixir term types" do
      complex_shared = %{
        atom_val: :hello,
        string_val: "world",
        integer_val: 42,
        float_val: 3.14,
        list_val: [1, :two, "three"],
        tuple_val: {:ok, "data"},
        nested: %{deep: %{value: true}},
        nil_val: nil
      }

      cp = build_checkpoint(sequence: 1, shared: complex_shared)
      Memory.save("run-1", cp)

      {:ok, loaded} = Memory.load_latest("run-1")
      assert loaded.shared == complex_shared
    end

    test "inserted_at is set automatically on save" do
      before = DateTime.utc_now()
      Memory.save("run-1", build_checkpoint(sequence: 1))
      {:ok, loaded} = Memory.load_latest("run-1")

      assert DateTime.compare(loaded.inserted_at, before) in [:eq, :gt]
    end
  end

  # ===========================================================================
  # Helper
  # ===========================================================================

  defp build_checkpoint(overrides) do
    defaults = %{
      run_id: Keyword.get(overrides, :run_id, "test-run"),
      sequence: Keyword.get(overrides, :sequence, 1),
      event_type: Keyword.get(overrides, :event_type, :node_completed),
      flow_name: Keyword.get(overrides, :flow_name, "TestFlow"),
      node_id: Keyword.get(overrides, :node_id, :test_node),
      next_node_id: Keyword.get(overrides, :next_node_id, :next_node),
      action: Keyword.get(overrides, :action, :default),
      shared: Keyword.get(overrides, :shared, %{data: "test"}),
      error_info: Keyword.get(overrides, :error_info, nil)
    }

    defaults
  end
end
