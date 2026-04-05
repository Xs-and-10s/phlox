defmodule Phlox.FlowSupervisorTest do
  # async: false — these tests interact with the shared Registry and DynamicSupervisor
  # started by the application. Concurrent tests would clobber each other's named flows.
  use ExUnit.Case, async: false

  alias Phlox.{FlowSupervisor, FlowServer}

  # ===========================================================================
  # Test nodes
  # ===========================================================================

  defmodule EchoNode do
    use Phlox.Node

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :echo, true)}
    end
  end

  defmodule SlowNode do
    use Phlox.Node

    def exec(_prep, params) do
      Process.sleep(Map.get(params, :delay_ms, 50))
      :ok
    end

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :slow, true)}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp unique_name do
    :"flow_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp simple_flow do
    %Phlox.Flow{
      start_id: :echo,
      nodes: %{
        echo: %{
          id: :echo,
          module: EchoNode,
          params: %{},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  defp slow_flow(delay_ms) do
    %Phlox.Flow{
      start_id: :slow,
      nodes: %{
        slow: %{
          id: :slow,
          module: SlowNode,
          params: %{delay_ms: delay_ms},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  # ===========================================================================
  # start_flow/3
  # ===========================================================================

  test "start_flow/3 spawns a FlowServer process" do
    name = unique_name()
    {:ok, pid} = FlowSupervisor.start_flow(name, simple_flow())
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

    assert %{status: :ready, shared: %{value: 42}} =
             FlowServer.state(FlowSupervisor.server(name))
  end

  # ===========================================================================
  # stop_flow/1
  # ===========================================================================

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

  # ===========================================================================
  # whereis/1
  # ===========================================================================

  test "whereis/1 returns nil for an unknown name" do
    assert FlowSupervisor.whereis(:no_such_flow) == nil
  end

  test "whereis/1 returns nil after a flow is stopped" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow())
    FlowSupervisor.stop_flow(name)

    assert FlowSupervisor.whereis(name) == nil
  end

  # ===========================================================================
  # running/0
  # ===========================================================================

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

  # ===========================================================================
  # end-to-end via supervisor
  # ===========================================================================

  test "can run a flow to completion via supervisor-spawned server" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow(), %{hello: :world})

    assert {:ok, %{echo: true, hello: :world}} =
             FlowServer.run(FlowSupervisor.server(name))
  end

  test "can step through a flow via supervisor-spawned server" do
    name = unique_name()
    FlowSupervisor.start_flow(name, simple_flow(), %{})

    assert {:done, %{echo: true}} =
             FlowServer.step(FlowSupervisor.server(name))
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
