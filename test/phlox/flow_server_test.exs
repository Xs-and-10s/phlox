defmodule Phlox.FlowServerTest do
  use ExUnit.Case, async: true

  alias Phlox.{Graph, FlowServer}

  # ---------------------------------------------------------------------------
  # Node fixtures
  # ---------------------------------------------------------------------------

  defmodule IncrNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.get(shared, :count, 0)
    def exec(count, _p), do: count + 1
    def post(shared, _prep, result, _p), do: {:default, Map.put(shared, :count, result)}
  end

  defmodule TagNode do
    use Phlox.Node
    def post(shared, _prep, _exec, params) do
      {:default, Map.put(shared, :tag, params.tag)}
    end
  end

  defmodule BranchNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.get(shared, :count, 0)
    def exec(count, _p), do: count
    def post(shared, _prep, count, _p) when count >= 3, do: {"done", shared}
    def post(shared, _prep, _count, _p), do: {"again", shared}
  end

  defmodule ExplodeNode do
    use Phlox.Node
    def exec(_prep, _p), do: raise(RuntimeError, "server boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp simple_flow do
    Graph.new()
    |> Graph.add_node(:incr, IncrNode, %{})
    |> Graph.add_node(:tag, TagNode, %{tag: :finished})
    |> Graph.connect(:incr, :tag)
    |> Graph.start_at(:incr)
    |> Graph.to_flow!()
  end

  defp branch_flow do
    # incr → branch → (again → incr | done → tag)
    Graph.new()
    |> Graph.add_node(:incr, IncrNode, %{})
    |> Graph.add_node(:branch, BranchNode, %{})
    |> Graph.add_node(:tag, TagNode, %{tag: :done})
    |> Graph.connect(:incr, :branch)
    |> Graph.connect(:branch, :incr, action: "again")
    |> Graph.connect(:branch, :tag, action: "done")
    |> Graph.start_at(:incr)
    |> Graph.to_flow!()
  end

  defp error_flow do
    Graph.new()
    |> Graph.add_node(:boom, ExplodeNode, %{}, max_retries: 1)
    |> Graph.start_at(:boom)
    |> Graph.to_flow!()
  end

  # ---------------------------------------------------------------------------
  # start_link / init
  # ---------------------------------------------------------------------------

  test "starts successfully with a valid flow" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{x: 1})
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "initial state has status :ready and the starting node" do
    flow = simple_flow()
    {:ok, pid} = FlowServer.start_link(flow: flow, shared: %{})

    snap = FlowServer.state(pid)
    assert snap.status == :ready
    assert snap.current_id == :incr

    # FlowServer injects :phlox_flow_id (from run_id) when the user omits it
    assert is_binary(snap.shared.phlox_flow_id)
    assert String.length(snap.shared.phlox_flow_id) == 32
    assert snap.flow_id == snap.shared.phlox_flow_id
    assert Map.delete(snap.shared, :phlox_flow_id) == %{}
  end

  # ---------------------------------------------------------------------------
  # run/1
  # ---------------------------------------------------------------------------

  test "run/1 executes all nodes and returns final shared" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})

    assert {:ok, %{count: 1, tag: :finished}} = FlowServer.run(pid)
  end

  test "run/1 updates server status to :done" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    FlowServer.run(pid)

    assert %{status: :done, current_id: nil} = FlowServer.state(pid)
  end

  test "run/1 returns {:error, _} when a node raises" do
    {:ok, pid} = FlowServer.start_link(flow: error_flow(), shared: %{})

    assert {:error, %RuntimeError{message: "server boom"}} = FlowServer.run(pid)
  end

  test "run/1 returns error when called on an already-done server" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    FlowServer.run(pid)

    assert {:error, {:invalid_status, :done}} = FlowServer.run(pid)
  end

  test "run/1 handles looping flows correctly (branch loop 3 times)" do
    {:ok, pid} = FlowServer.start_link(flow: branch_flow(), shared: %{})

    assert {:ok, %{count: 3, tag: :done}} = FlowServer.run(pid)
  end

  # ---------------------------------------------------------------------------
  # step/1
  # ---------------------------------------------------------------------------

  test "step/1 advances one node at a time" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})

    # Step 1: IncrNode (count: 0 → 1), next is :tag
    assert {:continue, :tag, %{count: 1}} = FlowServer.step(pid)

    # Step 2: TagNode, no successor — done
    assert {:done, %{count: 1, tag: :finished}} = FlowServer.step(pid)
  end

  test "step/1 returns {:done, shared} when called after completion" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    FlowServer.step(pid)
    FlowServer.step(pid)

    # Already done — idempotent
    assert {:done, %{count: 1, tag: :finished}} = FlowServer.step(pid)
  end

  test "step/1 returns {:error, exc} when a node raises" do
    {:ok, pid} = FlowServer.start_link(flow: error_flow(), shared: %{})

    assert {:error, %RuntimeError{message: "server boom"}} = FlowServer.step(pid)
  end

  test "step/1 updates current_id between steps" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    assert %{current_id: :incr} = FlowServer.state(pid)

    FlowServer.step(pid)
    assert %{current_id: :tag} = FlowServer.state(pid)

    FlowServer.step(pid)
    assert %{current_id: nil, status: :done} = FlowServer.state(pid)
  end

  # ---------------------------------------------------------------------------
  # reset/2
  # ---------------------------------------------------------------------------

  test "reset/1 returns server to :ready from :done" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    FlowServer.run(pid)

    assert :ok = FlowServer.reset(pid)
    assert %{status: :ready, current_id: :incr} = FlowServer.state(pid)
  end

  test "reset/2 replaces shared state" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{count: 99})
    FlowServer.run(pid)

    FlowServer.reset(pid, %{count: 0})
    assert %{shared: %{count: 0}} = FlowServer.state(pid)
  end

  test "reset then run produces a fresh result" do
    {:ok, pid} = FlowServer.start_link(flow: simple_flow(), shared: %{})
    {:ok, first} = FlowServer.run(pid)

    FlowServer.reset(pid)
    {:ok, second} = FlowServer.run(pid)

    assert first == second
  end

  # ---------------------------------------------------------------------------
  # Named server
  # ---------------------------------------------------------------------------

  test "can be started and addressed by name" do
    name = :"test_flow_server_#{System.unique_integer([:positive])}"
    {:ok, _pid} = FlowServer.start_link(flow: simple_flow(), shared: %{}, name: name)

    assert {:ok, %{count: 1}} = FlowServer.run(name)
  end
end
