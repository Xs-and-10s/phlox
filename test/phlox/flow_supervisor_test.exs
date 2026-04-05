defmodule Phlox.FlowSupervisorTest do
  # async: false — these tests interact with the shared Registry and DynamicSupervisor
  # started by the application. Concurrent tests would clobber each other's named flows.
  use ExUnit.Case, async: false

  alias Phlox.{Graph, FlowServer, FlowSupervisor}

  # ---------------------------------------------------------------------------
  # Node fixtures
  # ---------------------------------------------------------------------------

  defmodule EchoNode do
    use Phlox.Node
    def prep(shared, _p), do: shared
    def exec(shared, _p), do: shared
    def post(_old_shared, _prep, shared, _p), do: {:default, Map.put(shared, :echo, true)}
  end

  defmodule SlowNode do
    use Phlox.Node
    def exec(_prep, params) do
      Process.sleep(Map.get(params, :sleep_ms, 50))
      :done
    end
    def post(shared, _prep, :done, _p), do: {:default, Map.put(shared, :slow, true)}
  end

  defmodule ExplodeNode do
    use Phlox.Node
    def exec(_prep, _p), do: raise(RuntimeError, "sup boom")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp simple_flow do
    Graph.new()
    |> Graph.add_node(:echo, EchoNode, %{})
    |> Graph.start_at(:echo)
    |> Graph.to_flow!()
  end

  defp slow_flow(sleep_ms) do
    Graph.new()
    |> Graph.add_node(:slow, SlowNode, %{sleep_ms: sleep_ms})
    |> Graph.start_at(:slow)
    |> Graph.to_flow!()
  end

  # Unique name per test to avoid cross-test pollution
  defp unique_name, do: :"flow_#{System.unique_integer([:positive])}"

  # Ensure named flows are cleaned up after each test
  setup do
    on_exit(fn ->
      FlowSupervisor.running()
      |> Enum.each(&FlowSupervisor.stop_flow/1)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # start_flow/4
  # ---------------------------------------------------------------------------

  test "start_flow/3 spawns a live FlowServer process" do
    name = unique_name()
    assert {:ok, pid} = FlowSupervisor.start_flow(name, simple_flow())
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "start_flow/3 registers the process under the given name" do
    name = unique_name()
    {:ok, pid} = FlowSupervisor.start_flow(name, simple_flow())
    assert FlowSupervisor.whereis(name) == pid
  end

  test "start_flow/3 returns error if name already in use" do
    name = unique_name()
    {:ok, _} = FlowSupervisor.start_flow(name, simple_flow())

    assert {:error, {:already_started, _pid}} = FlowSupervisor.start_flow(name, simple_flow())
  end

  test "spawned flow starts in :ready status" do
    name = unique_name()
    {:ok, _} = FlowSupervisor.start_flow(name, simple_flow(), %{value: 42})

    assert %{status: :ready, shared: %{value: 42}} = FlowServer.state(FlowSupervisor.server(name))
  end

  # ---------------------------------------------------------------------------
  # stop_flow/1
  # ---------------------------------------------------------------------------

  test "stop_flow/1 terminates the process" do
    name = unique_name()
    {:ok, pid} = FlowSupervisor.start_flow(name, simple_flow())

    assert :ok = FlowSupervisor.stop_flow(name)
    refute Process.alive?(pid)
  end

  test "stop_flow/1 removes the name from the registry" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow())
    FlowSupervisor.stop_flow(name)

    assert FlowSupervisor.whereis(name) == nil
  end

  test "stop_flow/1 returns {:error, :not_found} for unknown name" do
    assert {:error, :not_found} = FlowSupervisor.stop_flow(:definitely_does_not_exist)
  end

  # ---------------------------------------------------------------------------
  # whereis/1
  # ---------------------------------------------------------------------------

  test "whereis/1 returns nil for an unknown name" do
    assert FlowSupervisor.whereis(:no_such_flow) == nil
  end

  test "whereis/1 returns nil after a flow is stopped" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow())
    FlowSupervisor.stop_flow(name)

    assert FlowSupervisor.whereis(name) == nil
  end

  # ---------------------------------------------------------------------------
  # running/0
  # ---------------------------------------------------------------------------

  test "running/0 lists all active flow names" do
    a = unique_name()
    b = unique_name()
    FlowSupervisor.start_flow(a, simple_flow())
    FlowSupervisor.start_flow(b, simple_flow())

    names = FlowSupervisor.running()
    assert a in names
    assert b in names
  end

  test "running/0 does not include stopped flows" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow())
    FlowSupervisor.stop_flow(name)

    refute name in FlowSupervisor.running()
  end

  # ---------------------------------------------------------------------------
  # end-to-end via supervisor
  # ---------------------------------------------------------------------------

  test "can run a flow to completion via supervisor-spawned server" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow(), %{hello: :world})

    assert {:ok, %{echo: true, hello: :world}} = FlowServer.run(FlowSupervisor.server(name))
  end

  test "can step through a flow via supervisor-spawned server" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow(), %{})

    assert {:done, %{echo: true}} = FlowServer.step(FlowSupervisor.server(name))
  end

  test "multiple named flows run concurrently without interference" do
    names = for _ <- 1..5, do: unique_name()

    # Start all
    for name <- names do
      FlowSupervisor.start_flow(name, slow_flow(20), %{id: name})
    end

    # Run all concurrently via tasks
    results =
      names
      |> Task.async_stream(
        fn name -> {name, FlowServer.run(FlowSupervisor.server(name))} end,
        timeout: 5000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    for {name, {:ok, shared}} <- results do
      assert shared[:slow] == true
      assert shared[:id] == name
    end
  end

  test "temporary flow (default) is not restarted after it crashes" do
    name = unique_name()
    {:ok, pid} = FlowSupervisor.start_flow(name, simple_flow())

    # Kill the process directly (simulating a VM-level crash, not a node error)
    Process.exit(pid, :kill)
    Process.sleep(50)  # give the supervisor a moment

    # Should be gone — not restarted
    assert FlowSupervisor.whereis(name) == nil
  end
end
