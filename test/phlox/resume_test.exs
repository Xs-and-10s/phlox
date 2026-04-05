defmodule Phlox.ResumeTest do
  use ExUnit.Case, async: false

  alias Phlox.{Flow, Pipeline, Resume}
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

  defmodule BranchNode do
    use Phlox.Node

    def prep(shared, _p), do: Map.get(shared, :branch, :default)
    def exec(branch, _p), do: branch
    def post(shared, _prep, action, _p), do: {action, shared}
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

  defp checkpoint_opts do
    {Phlox.Checkpoint.Memory, []}
  end

  defp run_checkpointed(run_id, flow, shared \\ %{}) do
    {adapter, adapter_opts} = checkpoint_opts()

    Pipeline.orchestrate(flow, flow.start_id, shared,
      run_id: run_id,
      middlewares: [Phlox.Middleware.Checkpoint],
      metadata: %{
        checkpoint: {adapter, adapter_opts},
        flow_name: "TestFlow"
      }
    )
  end

  # ===========================================================================
  # Tests: resume
  # ===========================================================================

  describe "resume/2" do
    test "resumes from the latest checkpoint" do
      # Run a flow that checkpoints, then simulate a "crash" by
      # loading the checkpoint and resuming
      run_checkpointed("resume-1", three_node_flow())

      # Rewind to after :a so there's something to resume from
      {:ok, cp} = Memory.load_at("resume-1", :a)
      # Manually set the latest checkpoint to :a by deleting and re-saving
      Memory.delete("resume-1")
      Memory.save("resume-1", cp)

      {:ok, result} = Resume.resume("resume-1",
        flow: three_node_flow(),
        checkpoint: checkpoint_opts()
      )

      assert result.trail == [:first, :second, :third]
    end

    test "returns error when run_id has no checkpoints" do
      assert {:error, {:no_checkpoint, "nonexistent"}} =
               Resume.resume("nonexistent",
                 flow: three_node_flow(),
                 checkpoint: checkpoint_opts()
               )
    end

    test "returns error when flow already completed" do
      run_checkpointed("completed", three_node_flow())

      assert {:error, {:flow_already_completed, "completed"}} =
               Resume.resume("completed",
                 flow: three_node_flow(),
                 checkpoint: checkpoint_opts()
               )
    end

    test "resumed run appends checkpoints to the same run_id by default" do
      run_checkpointed("append-test", three_node_flow())

      # Rewind to after :a
      {:ok, cp} = Memory.load_at("append-test", :a)
      Memory.delete("append-test")
      Memory.save("append-test", cp)

      Resume.resume("append-test",
        flow: three_node_flow(),
        checkpoint: checkpoint_opts()
      )

      {:ok, history} = Memory.history("append-test")
      # Original :a checkpoint + resumed :b and :c
      assert length(history) == 3
    end

    test "resumed run can use a different run_id" do
      run_checkpointed("original", three_node_flow())

      {:ok, cp} = Memory.load_at("original", :a)
      Memory.delete("original")
      Memory.save("original", cp)

      Resume.resume("original",
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        run_id: "fork-1"
      )

      {:ok, fork_history} = Memory.history("fork-1")
      assert length(fork_history) == 2
      node_ids = Enum.map(fork_history, & &1.node_id)
      assert node_ids == [:b, :c]
    end

    test "includes additional middlewares when provided" do
      defmodule TagMiddleware do
        @behaviour Phlox.Middleware
        @impl true
        def after_node(shared, action, _ctx) do
          {:cont, Map.put(shared, :tagged, true), action}
        end
      end

      run_checkpointed("mw-test", three_node_flow())

      {:ok, cp} = Memory.load_at("mw-test", :b)
      Memory.delete("mw-test")
      Memory.save("mw-test", cp)

      {:ok, result} = Resume.resume("mw-test",
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        middlewares: [TagMiddleware]
      )

      assert result.tagged == true
    end
  end

  # ===========================================================================
  # Tests: rewind
  # ===========================================================================

  describe "rewind/3" do
    test "rewinds to a specific node and re-executes downstream" do
      run_checkpointed("rewind-1", three_node_flow())

      {:ok, result} = Resume.rewind("rewind-1", :a,
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        run_id: "rewind-1-redo"
      )

      # Resumed from after :a, so :b and :c re-executed
      assert result.trail == [:first, :second, :third]
    end

    test "rewind to middle node skips earlier nodes" do
      run_checkpointed("rewind-mid", three_node_flow())

      {:ok, result} = Resume.rewind("rewind-mid", :b,
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        run_id: "rewind-mid-redo"
      )

      # Resumed from after :b, only :c re-executed
      assert result.trail == [:first, :second, :third]

      {:ok, redo_history} = Memory.history("rewind-mid-redo")
      node_ids = Enum.map(redo_history, & &1.node_id)
      assert node_ids == [:c]
    end

    test "returns error when node_id not found in checkpoints" do
      run_checkpointed("rewind-missing", three_node_flow())

      assert {:error, {:no_checkpoint_at, "rewind-missing", :nonexistent}} =
               Resume.rewind("rewind-missing", :nonexistent,
                 flow: three_node_flow(),
                 checkpoint: checkpoint_opts()
               )
    end

    test "returns error when run_id not found" do
      assert {:error, {:no_checkpoint_at, "nope", :a}} =
               Resume.rewind("nope", :a,
                 flow: three_node_flow(),
                 checkpoint: checkpoint_opts()
               )
    end

    test "rewind preserves shared state from the target checkpoint" do
      run_checkpointed("rewind-state", three_node_flow(), %{extra: :data})

      {:ok, result} = Resume.rewind("rewind-state", :a,
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        run_id: "rewind-state-redo"
      )

      assert result.extra == :data
      assert result.trail == [:first, :second, :third]
    end
  end

  # ===========================================================================
  # Tests: error handling
  # ===========================================================================

  describe "error handling" do
    test "raises when :flow is missing" do
      assert_raise KeyError, fn ->
        Resume.resume("x", checkpoint: checkpoint_opts())
      end
    end

    test "raises when :checkpoint is missing" do
      assert_raise ArgumentError, ~r/requires a :checkpoint option/, fn ->
        Resume.resume("x", flow: three_node_flow())
      end
    end

    test "raises when :checkpoint is malformed" do
      assert_raise ArgumentError, ~r/Expected :checkpoint to be/, fn ->
        Resume.resume("x",
          flow: three_node_flow(),
          checkpoint: "wrong"
        )
      end
    end

    test "raises when checkpoint targets a node not in the flow" do
      # Manually save a checkpoint pointing to a node that doesn't exist
      Memory.save("bad-target", %{
        run_id: "bad-target",
        sequence: 1,
        event_type: :node_completed,
        flow_name: "Test",
        node_id: :a,
        next_node_id: :nonexistent,
        action: :default,
        shared: %{},
        error_info: nil
      })

      assert_raise ArgumentError, ~r/node :nonexistent/, fn ->
        Resume.resume("bad-target",
          flow: three_node_flow(),
          checkpoint: checkpoint_opts()
        )
      end
    end
  end

  # ===========================================================================
  # Tests: metadata
  # ===========================================================================

  describe "metadata" do
    defmodule MetaCapture do
      @behaviour Phlox.Middleware
      @impl true
      def before_node(shared, ctx) do
        {:cont, Map.put(shared, :_resumed_from, ctx.metadata[:resumed_from])}
      end
    end

    test "resume injects :resumed_from metadata into pipeline context" do
      run_checkpointed("meta-test", three_node_flow())

      {:ok, cp} = Memory.load_at("meta-test", :b)
      Memory.delete("meta-test")
      Memory.save("meta-test", cp)

      {:ok, result} = Resume.resume("meta-test",
        flow: three_node_flow(),
        checkpoint: checkpoint_opts(),
        middlewares: [MetaCapture]
      )

      resumed_from = result._resumed_from
      assert resumed_from.original_run_id == "meta-test"
      assert resumed_from.node_id == :b
      assert resumed_from.sequence == 2
    end
  end
end
