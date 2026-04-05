defmodule Phlox.Middleware.CheckpointTest do
  use ExUnit.Case, async: false

  alias Phlox.{Flow, Pipeline}
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

    def post(shared, _prep, action, _params) do
      {action, shared}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp pipeline_opts(overrides) do
    run_id = Keyword.get(overrides, :run_id, "test-run-#{System.unique_integer([:positive])}")
    flow_name = Keyword.get(overrides, :flow_name, "TestFlow")
    extra_mw = Keyword.get(overrides, :extra_middlewares, [])

    [
      run_id: run_id,
      middlewares: extra_mw ++ [Phlox.Middleware.Checkpoint],
      metadata: %{
        checkpoint: {Memory, []},
        flow_name: flow_name
      }
    ]
  end

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

  defp branching_flow do
    %Flow{
      start_id: :router,
      nodes: %{
        router: %{id: :router, module: BranchNode, params: %{},
                  successors: %{"default" => :left, "right" => :right},
                  max_retries: 1, wait_ms: 0},
        left: %{id: :left, module: AccNode, params: %{value: :went_left},
                successors: %{}, max_retries: 1, wait_ms: 0},
        right: %{id: :right, module: AccNode, params: %{value: :went_right},
                 successors: %{}, max_retries: 1, wait_ms: 0}
      }
    }
  end

  # ===========================================================================
  # Tests: checkpoint saving
  # ===========================================================================

  describe "checkpoint saving" do
    test "saves a checkpoint after each node" do
      opts = pipeline_opts(run_id: "save-each")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("save-each")
      assert length(entries) == 3
    end

    test "checkpoints have monotonically increasing sequence numbers" do
      opts = pipeline_opts(run_id: "seq-test")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("seq-test")
      sequences = Enum.map(entries, & &1.sequence)
      assert sequences == [1, 2, 3]
    end

    test "each checkpoint records the node that just completed" do
      opts = pipeline_opts(run_id: "node-ids")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("node-ids")
      node_ids = Enum.map(entries, & &1.node_id)
      assert node_ids == [:a, :b, :c]
    end

    test "each checkpoint records the next node to execute" do
      opts = pipeline_opts(run_id: "next-ids")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("next-ids")
      next_ids = Enum.map(entries, & &1.next_node_id)
      assert next_ids == [:b, :c, nil]
    end

    test "intermediate checkpoints are :node_completed, last is :flow_completed" do
      opts = pipeline_opts(run_id: "event-types")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("event-types")
      types = Enum.map(entries, & &1.event_type)
      assert types == [:node_completed, :node_completed, :flow_completed]
    end

    test "shared state is captured progressively" do
      opts = pipeline_opts(run_id: "progressive")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("progressive")

      trails = Enum.map(entries, fn e -> e.shared.trail end)
      assert trails == [[:first], [:first, :second], [:first, :second, :third]]
    end

    test "flow_name from metadata is stored in each checkpoint" do
      opts = pipeline_opts(run_id: "named", flow_name: "IngestPipeline")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("named")

      assert Enum.all?(entries, fn e -> e.flow_name == "IngestPipeline" end)
    end

    test "run_id is stored in each checkpoint" do
      opts = pipeline_opts(run_id: "my-run")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("my-run")

      assert Enum.all?(entries, fn e -> e.run_id == "my-run" end)
    end

    test "action is stored in each checkpoint" do
      opts = pipeline_opts(run_id: "actions")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, entries} = Memory.history("actions")

      assert Enum.all?(entries, fn e -> e.action == :default end)
    end
  end

  # ===========================================================================
  # Tests: branching flows
  # ===========================================================================

  describe "branching flows" do
    test "checkpoints follow the taken branch (default)" do
      opts = pipeline_opts(run_id: "branch-left")
      Pipeline.orchestrate(branching_flow(), :router, %{}, opts)

      {:ok, entries} = Memory.history("branch-left")
      node_ids = Enum.map(entries, & &1.node_id)
      assert node_ids == [:router, :left]
    end

    test "checkpoints follow the taken branch (right)" do
      opts = pipeline_opts(run_id: "branch-right")
      Pipeline.orchestrate(branching_flow(), :router, %{branch: "right"}, opts)

      {:ok, entries} = Memory.history("branch-right")
      node_ids = Enum.map(entries, & &1.node_id)
      assert node_ids == [:router, :right]
    end

    test "checkpoint records non-default action for branch node" do
      opts = pipeline_opts(run_id: "branch-action")
      Pipeline.orchestrate(branching_flow(), :router, %{branch: "right"}, opts)

      {:ok, entries} = Memory.history("branch-action")
      [router_cp, _right_cp] = entries
      assert router_cp.action == "right"
      assert router_cp.next_node_id == :right
    end
  end

  # ===========================================================================
  # Tests: resume from checkpoint
  # ===========================================================================

  describe "resume from checkpoint" do
    test "can resume from the latest checkpoint" do
      # Run the flow — it checkpoints after each node
      opts = pipeline_opts(run_id: "resume-test")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      # Verify the flow completed
      {:ok, latest} = Memory.load_latest("resume-test")
      assert latest.event_type == :flow_completed
      assert latest.next_node_id == nil
    end

    test "can resume from a mid-flow checkpoint" do
      # Run the full flow first
      opts = pipeline_opts(run_id: "mid-resume")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      # Load the checkpoint after node :a (sequence 1)
      {:ok, cp} = Memory.load_at("mid-resume", :a)
      assert cp.next_node_id == :b
      assert cp.shared.trail == [:first]

      # Resume from :b with the checkpointed shared
      resume_opts = pipeline_opts(run_id: "mid-resume-2")
      result = Pipeline.orchestrate(three_node_flow(), cp.next_node_id, cp.shared, resume_opts)

      # Should have completed :b and :c
      assert result.trail == [:first, :second, :third]

      # The resumed run should have its own checkpoint history
      {:ok, resume_entries} = Memory.history("mid-resume-2")
      assert length(resume_entries) == 2
      node_ids = Enum.map(resume_entries, & &1.node_id)
      assert node_ids == [:b, :c]
    end

    test "resumed run's first checkpoint captures the carried-over shared" do
      opts = pipeline_opts(run_id: "carry-over")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, cp} = Memory.load_at("carry-over", :a)

      resume_opts = pipeline_opts(run_id: "carry-over-2")
      Pipeline.orchestrate(three_node_flow(), cp.next_node_id, cp.shared, resume_opts)

      {:ok, [first | _]} = Memory.history("carry-over-2")
      # First checkpoint of resumed run = node :b, shared has trail from :a
      assert first.node_id == :b
      assert :first in first.shared.trail
    end
  end

  # ===========================================================================
  # Tests: rewind
  # ===========================================================================

  describe "rewind" do
    test "can rewind to a specific node and re-execute from there" do
      opts = pipeline_opts(run_id: "rewind-test")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      # Rewind to after node :a — re-run :b and :c
      {:ok, cp} = Memory.load_at("rewind-test", :a)

      rewind_opts = pipeline_opts(run_id: "rewind-2")
      result = Pipeline.orchestrate(three_node_flow(), cp.next_node_id, cp.shared, rewind_opts)

      assert result.trail == [:first, :second, :third]
    end

    test "rewind checkpoint is findable by node_id" do
      opts = pipeline_opts(run_id: "rewind-find")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, cp_a} = Memory.load_at("rewind-find", :a)
      {:ok, cp_b} = Memory.load_at("rewind-find", :b)

      assert cp_a.node_id == :a
      assert cp_a.next_node_id == :b
      assert cp_b.node_id == :b
      assert cp_b.next_node_id == :c
    end
  end

  # ===========================================================================
  # Tests: list_resumable
  # ===========================================================================

  describe "list_resumable integration" do
    test "completed flow is not resumable" do
      opts = pipeline_opts(run_id: "completed")
      Pipeline.orchestrate(three_node_flow(), :a, %{}, opts)

      {:ok, resumable} = Memory.list_resumable()
      run_ids = Enum.map(resumable, & &1.run_id)
      refute "completed" in run_ids
    end
  end

  # ===========================================================================
  # Tests: single-node flow
  # ===========================================================================

  describe "single-node flow" do
    test "produces exactly one checkpoint with :flow_completed" do
      flow = %Flow{
        start_id: :only,
        nodes: %{
          only: %{id: :only, module: AccNode, params: %{value: :solo},
                  successors: %{}, max_retries: 1, wait_ms: 0}
        }
      }

      opts = pipeline_opts(run_id: "single")
      Pipeline.orchestrate(flow, :only, %{}, opts)

      {:ok, entries} = Memory.history("single")
      assert length(entries) == 1
      [entry] = entries
      assert entry.event_type == :flow_completed
      assert entry.node_id == :only
      assert entry.next_node_id == nil
      assert entry.sequence == 1
    end
  end

  # ===========================================================================
  # Tests: error handling
  # ===========================================================================

  describe "error handling" do
    test "raises ArgumentError when checkpoint metadata is missing" do
      assert_raise ArgumentError, ~r/requires :checkpoint in pipeline metadata/, fn ->
        Pipeline.orchestrate(three_node_flow(), :a, %{},
          middlewares: [Phlox.Middleware.Checkpoint],
          metadata: %{}
        )
      end
    end

    test "raises ArgumentError when checkpoint metadata is malformed" do
      assert_raise ArgumentError, ~r/Expected :checkpoint metadata/, fn ->
        Pipeline.orchestrate(three_node_flow(), :a, %{},
          middlewares: [Phlox.Middleware.Checkpoint],
          metadata: %{checkpoint: "wrong"}
        )
      end
    end
  end

  # ===========================================================================
  # Tests: middleware ordering interaction
  # ===========================================================================

  describe "middleware ordering" do
    defmodule InjectMiddleware do
      @behaviour Phlox.Middleware

      @impl true
      def after_node(shared, action, _ctx) do
        {:cont, Map.put(shared, :injected, true), action}
      end
    end

    test "checkpoint captures modifications from earlier after_node middlewares" do
      # InjectMiddleware is listed BEFORE Checkpoint, so its after_node
      # runs AFTER Checkpoint's (reverse order). That means Checkpoint
      # would NOT see :injected.
      #
      # But if we put InjectMiddleware AFTER Checkpoint, its after_node
      # runs FIRST (reverse order), so Checkpoint DOES see :injected.

      # We need InjectMiddleware AFTER Checkpoint for its after_node
      # to run first. Override the middleware list directly.
      flow = %Flow{
        start_id: :x,
        nodes: %{
          x: %{id: :x, module: AccNode, params: %{value: :done},
               successors: %{}, max_retries: 1, wait_ms: 0}
        }
      }

      result = Pipeline.orchestrate(flow, :x, %{},
        run_id: "ordering",
        # Checkpoint is first in list → its after_node runs LAST
        # InjectMiddleware is second → its after_node runs FIRST
        middlewares: [Phlox.Middleware.Checkpoint, InjectMiddleware],
        metadata: %{
          checkpoint: {Memory, []},
          flow_name: "OrderTest"
        }
      )

      assert result.injected == true

      {:ok, [cp]} = Memory.history("ordering")
      # Checkpoint's after_node ran after InjectMiddleware's,
      # so it captured the :injected key
      assert cp.shared.injected == true
    end
  end
end
