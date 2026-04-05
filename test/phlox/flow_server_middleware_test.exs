defmodule Phlox.FlowServer.MiddlewareTest do
  use ExUnit.Case, async: false

  alias Phlox.{Flow, FlowServer}
  alias Phlox.Checkpoint.Memory

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
  # Test nodes
  # ===========================================================================

  defmodule AccNode do
    use Phlox.Node

    def exec(_prep, params), do: Map.get(params, :value, :done)

    def post(shared, _prep, exec_res, _params) do
      trail = Map.get(shared, :trail, [])
      {:default, Map.put(shared, :trail, trail ++ [exec_res])}
    end
  end

  # ===========================================================================
  # Test middlewares
  # ===========================================================================

  defmodule TagMiddleware do
    @behaviour Phlox.Middleware
    @impl true
    def after_node(shared, action, _ctx) do
      count = Map.get(shared, :tag_count, 0)
      {:cont, Map.put(shared, :tag_count, count + 1), action}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp three_node_flow do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{id: :a, module: AccNode, params: %{value: :first},
             successors: %{"default" => :b}, max_retries: 1, wait_ms: 0},
        b: %{id: :b, module: AccNode, params: %{value: :second},
             successors: %{"default" => :c}, max_retries: 1, wait_ms: 0},
        c: %{id: :c, module: AccNode, params: %{value: :third},
             successors: %{}, max_retries: 1, wait_ms: 0}
      }
    }
  end

  # ===========================================================================
  # Tests: run with middlewares
  # ===========================================================================

  describe "run/1 with middlewares" do
    test "uses Pipeline when middlewares are configured" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [TagMiddleware]
      )

      {:ok, result} = FlowServer.run(pid)

      assert result.trail == [:first, :second, :third]
      assert result.tag_count == 3
    end

    test "uses Runner when no middlewares (backward compatible)" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{}
      )

      {:ok, result} = FlowServer.run(pid)

      assert result.trail == [:first, :second, :third]
      refute Map.has_key?(result, :tag_count)
    end

    test "run with checkpoint middleware saves checkpoints" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "server-run-1",
        metadata: %{
          checkpoint: {Memory, []},
          flow_name: "TestFlow"
        }
      )

      {:ok, _result} = FlowServer.run(pid)

      {:ok, history} = Memory.history("server-run-1")
      assert length(history) == 3
      node_ids = Enum.map(history, & &1.node_id)
      assert node_ids == [:a, :b, :c]
    end
  end

  # ===========================================================================
  # Tests: step with middlewares
  # ===========================================================================

  describe "step/1 with middlewares" do
    test "fires middleware hooks on each step" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [TagMiddleware]
      )

      {:continue, :b, shared1} = FlowServer.step(pid)
      assert shared1.tag_count == 1

      {:continue, :c, shared2} = FlowServer.step(pid)
      assert shared2.tag_count == 2

      {:done, final} = FlowServer.step(pid)
      assert final.tag_count == 3
    end

    test "step with checkpoint middleware saves per step" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "step-cp",
        metadata: %{
          checkpoint: {Memory, []},
          flow_name: "StepTest"
        }
      )

      FlowServer.step(pid)
      {:ok, h1} = Memory.history("step-cp")
      assert length(h1) == 1

      FlowServer.step(pid)
      {:ok, h2} = Memory.history("step-cp")
      assert length(h2) == 2

      FlowServer.step(pid)
      {:ok, h3} = Memory.history("step-cp")
      assert length(h3) == 3
    end
  end

  # ===========================================================================
  # Tests: state snapshot
  # ===========================================================================

  describe "state/1" do
    test "includes run_id in snapshot" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        run_id: "my-run-42"
      )

      snapshot = FlowServer.state(pid)
      assert snapshot.run_id == "my-run-42"
    end

    test "auto-generates run_id when not provided" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{}
      )

      snapshot = FlowServer.state(pid)
      assert is_binary(snapshot.run_id)
      assert String.length(snapshot.run_id) == 32
    end
  end

  # ===========================================================================
  # Tests: reset
  # ===========================================================================

  describe "reset/2" do
    test "generates a new run_id on reset" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        run_id: "original"
      )

      %{run_id: original_id} = FlowServer.state(pid)
      assert original_id == "original"

      FlowServer.run(pid)
      FlowServer.reset(pid)

      %{run_id: new_id} = FlowServer.state(pid)
      refute new_id == "original"
    end
  end

  # ===========================================================================
  # Tests: resume from checkpoint
  # ===========================================================================

  describe "resume from checkpoint" do
    test "starts from the checkpointed node" do
      # First run: checkpoint after each node
      {:ok, pid1} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "resume-srv",
        metadata: %{checkpoint: {Memory, []}, flow_name: "Test"}
      )

      {:ok, _} = FlowServer.run(pid1)

      # Simulate partial run: delete all but the first checkpoint
      {:ok, cp} = Memory.load_at("resume-srv", :a)
      Memory.delete("resume-srv")
      Memory.save("resume-srv", cp)

      # Resume
      {:ok, pid2} = FlowServer.start_link(
        flow: three_node_flow(),
        resume: "resume-srv",
        checkpoint: {Memory, []},
        middlewares: [Phlox.Middleware.Checkpoint],
        metadata: %{checkpoint: {Memory, []}, flow_name: "Test"}
      )

      %{current_id: current} = FlowServer.state(pid2)
      assert current == :b

      {:ok, result} = FlowServer.run(pid2)
      assert result.trail == [:first, :second, :third]
    end

    test "fails to start when no checkpoint found for resume run_id" do
      Process.flag(:trap_exit, true)

      result = FlowServer.start_link(
        flow: three_node_flow(),
        resume: "nonexistent",
        checkpoint: {Memory, []}
      )

      assert {:error, {%ArgumentError{message: msg}, _}} = result
      assert msg =~ "no checkpoint found"
    end

    test "fails to start when flow already completed" do
      {:ok, pid} = FlowServer.start_link(
        flow: three_node_flow(),
        shared: %{},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "done-flow",
        metadata: %{checkpoint: {Memory, []}, flow_name: "Test"}
      )

      FlowServer.run(pid)

      Process.flag(:trap_exit, true)

      result = FlowServer.start_link(
        flow: three_node_flow(),
        resume: "done-flow",
        checkpoint: {Memory, []}
      )

      assert {:error, {%ArgumentError{message: msg}, _}} = result
      assert msg =~ "already completed"
    end

    test "fails to start when :checkpoint option is missing for resume" do
      Process.flag(:trap_exit, true)

      result = FlowServer.start_link(
        flow: three_node_flow(),
        resume: "some-run"
      )

      assert {:error, {%ArgumentError{message: msg}, _}} = result
      assert msg =~ "requires a :checkpoint option"
    end
  end
end
