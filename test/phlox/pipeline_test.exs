defmodule Phlox.PipelineTest do
  use ExUnit.Case, async: true

  alias Phlox.{Flow, Pipeline, HaltedError}

  # ===========================================================================
  # Test node modules
  # ===========================================================================

  defmodule PassthroughNode do
    @moduledoc false
    use Phlox.Node

    def prep(shared, _params), do: shared
    def exec(prep_res, _params), do: prep_res

    def post(shared, _prep_res, _exec_res, _params) do
      {:default, shared}
    end
  end

  defmodule AccumulatorNode do
    @moduledoc false
    use Phlox.Node

    def prep(shared, _params), do: shared

    def exec(_prep_res, params) do
      Map.get(params, :value, :no_value)
    end

    def post(shared, _prep_res, exec_res, _params) do
      trail = Map.get(shared, :trail, [])
      {:default, Map.put(shared, :trail, trail ++ [exec_res])}
    end
  end

  defmodule BranchingNode do
    @moduledoc false
    use Phlox.Node

    def prep(shared, _params), do: Map.get(shared, :branch, :default)
    def exec(branch, _params), do: branch

    def post(shared, _prep_res, exec_res, _params) do
      {exec_res, shared}
    end
  end

  # ===========================================================================
  # Test middleware modules
  # ===========================================================================

  defmodule TrackingMiddleware do
    @moduledoc "Records every before/after call into shared[:mw_log]"
    @behaviour Phlox.Middleware

    @impl true
    def before_node(shared, ctx) do
      entry = {:before, ctx.node_id, __MODULE__}
      log = Map.get(shared, :mw_log, [])
      {:cont, Map.put(shared, :mw_log, log ++ [entry])}
    end

    @impl true
    def after_node(shared, action, ctx) do
      entry = {:after, ctx.node_id, __MODULE__}
      log = Map.get(shared, :mw_log, [])
      {:cont, Map.put(shared, :mw_log, log ++ [entry]), action}
    end
  end

  defmodule SecondTrackingMiddleware do
    @moduledoc "A second tracker to verify ordering"
    @behaviour Phlox.Middleware

    @impl true
    def before_node(shared, ctx) do
      entry = {:before, ctx.node_id, __MODULE__}
      log = Map.get(shared, :mw_log, [])
      {:cont, Map.put(shared, :mw_log, log ++ [entry])}
    end

    @impl true
    def after_node(shared, action, ctx) do
      entry = {:after, ctx.node_id, __MODULE__}
      log = Map.get(shared, :mw_log, [])
      {:cont, Map.put(shared, :mw_log, log ++ [entry]), action}
    end
  end

  defmodule BeforeOnlyMiddleware do
    @moduledoc "Only implements before_node"
    @behaviour Phlox.Middleware

    @impl true
    def before_node(shared, _ctx) do
      count = Map.get(shared, :before_count, 0)
      {:cont, Map.put(shared, :before_count, count + 1)}
    end
  end

  defmodule AfterOnlyMiddleware do
    @moduledoc "Only implements after_node"
    @behaviour Phlox.Middleware

    @impl true
    def after_node(shared, action, _ctx) do
      count = Map.get(shared, :after_count, 0)
      {:cont, Map.put(shared, :after_count, count + 1), action}
    end
  end

  defmodule HaltBeforeMiddleware do
    @moduledoc "Halts in before_node if shared has :halt_before flag"
    @behaviour Phlox.Middleware

    @impl true
    def before_node(shared, _ctx) do
      if Map.get(shared, :halt_before) do
        {:halt, :budget_exceeded}
      else
        {:cont, shared}
      end
    end
  end

  defmodule HaltAfterMiddleware do
    @moduledoc "Halts in after_node if shared has :halt_after flag"
    @behaviour Phlox.Middleware

    @impl true
    def after_node(shared, action, _ctx) do
      if Map.get(shared, :halt_after) do
        {:halt, :approval_required}
      else
        {:cont, shared, action}
      end
    end
  end

  defmodule ActionRewriteMiddleware do
    @moduledoc "Rewrites action from :default to a custom route"
    @behaviour Phlox.Middleware

    @impl true
    def after_node(shared, _action, ctx) do
      if ctx.node_id == :router do
        {:cont, shared, Map.get(shared, :forced_route, :default)}
      else
        {:cont, shared, :default}
      end
    end
  end

  defmodule ContextCapture do
    @moduledoc "Captures the full context into shared for test assertions"
    @behaviour Phlox.Middleware

    @impl true
    def before_node(shared, ctx) do
      contexts = Map.get(shared, :captured_contexts, [])
      {:cont, Map.put(shared, :captured_contexts, contexts ++ [ctx])}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp single_node_flow do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{
          id: :a,
          module: PassthroughNode,
          params: %{},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  defp two_node_flow do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{
          id: :a,
          module: AccumulatorNode,
          params: %{value: :first},
          successors: %{"default" => :b},
          max_retries: 1,
          wait_ms: 0
        },
        b: %{
          id: :b,
          module: AccumulatorNode,
          params: %{value: :second},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  defp three_node_flow do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{
          id: :a,
          module: AccumulatorNode,
          params: %{value: :first},
          successors: %{"default" => :b},
          max_retries: 1,
          wait_ms: 0
        },
        b: %{
          id: :b,
          module: AccumulatorNode,
          params: %{value: :second},
          successors: %{"default" => :c},
          max_retries: 1,
          wait_ms: 0
        },
        c: %{
          id: :c,
          module: AccumulatorNode,
          params: %{value: :third},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  defp branching_flow do
    %Flow{
      start_id: :router,
      nodes: %{
        router: %{
          id: :router,
          module: BranchingNode,
          params: %{},
          successors: %{"default" => :left, "right" => :right},
          max_retries: 1,
          wait_ms: 0
        },
        left: %{
          id: :left,
          module: AccumulatorNode,
          params: %{value: :went_left},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        },
        right: %{
          id: :right,
          module: AccumulatorNode,
          params: %{value: :went_right},
          successors: %{},
          max_retries: 1,
          wait_ms: 0
        }
      }
    }
  end

  # ===========================================================================
  # Tests: basic orchestration (no middlewares — must match Runner)
  # ===========================================================================

  describe "orchestrate/4 without middlewares" do
    test "runs a single-node flow" do
      result = Pipeline.orchestrate(single_node_flow(), :a, %{hello: :world})
      assert result.hello == :world
      # Pipeline injects :phlox_flow_id when not provided by the caller
      assert is_binary(result.phlox_flow_id)
      assert Map.delete(result, :phlox_flow_id) == %{hello: :world}
    end

    test "runs a two-node pipeline and threads shared" do
      result = Pipeline.orchestrate(two_node_flow(), :a, %{})
      assert result.trail == [:first, :second]
    end

    test "runs a three-node pipeline" do
      result = Pipeline.orchestrate(three_node_flow(), :a, %{})
      assert result.trail == [:first, :second, :third]
    end

    test "auto-generates a run_id when not provided" do
      flow = single_node_flow()
      # Doesn't crash — run_id is generated internally
      result = Pipeline.orchestrate(flow, :a, %{})
      # The auto-generated run_id is also injected as :phlox_flow_id
      assert is_binary(result.phlox_flow_id)
      assert String.length(result.phlox_flow_id) == 32
      assert Map.delete(result, :phlox_flow_id) == %{}
    end

    test "raises ArgumentError for unknown start node" do
      flow = single_node_flow()

      assert_raise ArgumentError, ~r/node :nonexistent/, fn ->
        Pipeline.orchestrate(flow, :nonexistent, %{})
      end
    end
  end

  # ===========================================================================
  # Tests: middleware ordering
  # ===========================================================================

  describe "middleware ordering" do
    test "before_node called in list order, after_node in reverse" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [TrackingMiddleware, SecondTrackingMiddleware]
        )

      assert result.mw_log == [
               {:before, :a, TrackingMiddleware},
               {:before, :a, SecondTrackingMiddleware},
               # after is reversed: Second runs before First
               {:after, :a, SecondTrackingMiddleware},
               {:after, :a, TrackingMiddleware}
             ]
    end

    test "middlewares fire for every node in a multi-node flow" do
      flow = two_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [TrackingMiddleware]
        )

      before_entries = Enum.filter(result.mw_log, fn {dir, _, _} -> dir == :before end)
      after_entries = Enum.filter(result.mw_log, fn {dir, _, _} -> dir == :after end)

      assert length(before_entries) == 2
      assert length(after_entries) == 2

      # Order: before(:a), after(:a), before(:b), after(:b)
      assert result.mw_log == [
               {:before, :a, TrackingMiddleware},
               {:after, :a, TrackingMiddleware},
               {:before, :b, TrackingMiddleware},
               {:after, :b, TrackingMiddleware}
             ]
    end
  end

  # ===========================================================================
  # Tests: partial middleware (only before or only after)
  # ===========================================================================

  describe "partial middlewares" do
    test "before-only middleware is called, after is skipped" do
      flow = two_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [BeforeOnlyMiddleware]
        )

      assert result.before_count == 2
      refute Map.has_key?(result, :after_count)
    end

    test "after-only middleware is called, before is skipped" do
      flow = two_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [AfterOnlyMiddleware]
        )

      assert result.after_count == 2
      refute Map.has_key?(result, :before_count)
    end
  end

  # ===========================================================================
  # Tests: shared modification
  # ===========================================================================

  describe "shared modification by middlewares" do
    test "before_node can inject keys into shared before the node sees it" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [BeforeOnlyMiddleware]
        )

      assert result.before_count == 1
    end

    test "after_node can inject keys into shared after the node runs" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [AfterOnlyMiddleware]
        )

      assert result.after_count == 1
    end

    test "modifications accumulate across middlewares" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [BeforeOnlyMiddleware, AfterOnlyMiddleware]
        )

      assert result.before_count == 1
      assert result.after_count == 1
    end
  end

  # ===========================================================================
  # Tests: action rewriting
  # ===========================================================================

  describe "action rewriting" do
    test "after_node can rewrite the action to change routing" do
      flow = branching_flow()

      result =
        Pipeline.orchestrate(flow, :router, %{forced_route: "right"},
          middlewares: [ActionRewriteMiddleware]
        )

      assert result.trail == [:went_right]
    end

    test "default routing without rewrite middleware" do
      flow = branching_flow()

      result = Pipeline.orchestrate(flow, :router, %{})

      assert result.trail == [:went_left]
    end
  end

  # ===========================================================================
  # Tests: halting
  # ===========================================================================

  describe "halting" do
    test "before_node halt raises HaltedError" do
      flow = single_node_flow()

      error =
        assert_raise HaltedError, fn ->
          Pipeline.orchestrate(flow, :a, %{halt_before: true},
            middlewares: [HaltBeforeMiddleware]
          )
        end

      assert error.reason == :budget_exceeded
      assert error.node_id == :a
      assert error.middleware == HaltBeforeMiddleware
      assert error.phase == :before_node
    end

    test "after_node halt raises HaltedError" do
      flow = single_node_flow()

      error =
        assert_raise HaltedError, fn ->
          Pipeline.orchestrate(flow, :a, %{halt_after: true},
            middlewares: [HaltAfterMiddleware]
          )
        end

      assert error.reason == :approval_required
      assert error.node_id == :a
      assert error.middleware == HaltAfterMiddleware
      assert error.phase == :after_node
    end

    test "halt in before_node prevents the node from executing" do
      flow = two_node_flow()

      # Halts before node :a even runs, so no :trail key
      assert_raise HaltedError, fn ->
        Pipeline.orchestrate(flow, :a, %{halt_before: true},
          middlewares: [HaltBeforeMiddleware, TrackingMiddleware]
        )
      end
    end

    test "halt in after_node prevents subsequent nodes" do
      flow = two_node_flow()

      assert_raise HaltedError, fn ->
        Pipeline.orchestrate(flow, :a, %{halt_after: true},
          middlewares: [HaltAfterMiddleware]
        )
      end
    end

    test "HaltedError has a descriptive message" do
      error = %HaltedError{
        reason: :over_budget,
        node_id: :embed,
        middleware: HaltBeforeMiddleware,
        phase: :before_node
      }

      assert Exception.message(error) =~
               "Flow halted at :embed during before_node"

      assert Exception.message(error) =~ "HaltBeforeMiddleware"
      assert Exception.message(error) =~ ":over_budget"
    end
  end

  # ===========================================================================
  # Tests: context
  # ===========================================================================

  describe "context" do
    test "context includes node_id, flow, run_id, and metadata" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          run_id: "test-run-42",
          middlewares: [ContextCapture],
          metadata: %{flow_name: "TestFlow", custom: :data}
        )

      [ctx] = result.captured_contexts
      assert ctx.node_id == :a
      assert ctx.flow == flow
      assert ctx.run_id == "test-run-42"
      assert ctx.metadata == %{flow_name: "TestFlow", custom: :data}
      assert ctx.node.module == PassthroughNode
    end

    test "run_id is auto-generated as a 32-char hex string when not provided" do
      flow = single_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [ContextCapture]
        )

      [ctx] = result.captured_contexts
      assert is_binary(ctx.run_id)
      assert String.length(ctx.run_id) == 32
      assert ctx.run_id =~ ~r/^[0-9a-f]{32}$/
    end

    test "context.node updates for each node in the flow" do
      flow = two_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          middlewares: [ContextCapture]
        )

      node_ids = Enum.map(result.captured_contexts, & &1.node_id)
      assert node_ids == [:a, :b]
    end

    test "run_id stays consistent across all nodes" do
      flow = three_node_flow()

      result =
        Pipeline.orchestrate(flow, :a, %{},
          run_id: "stable-id",
          middlewares: [ContextCapture]
        )

      run_ids = Enum.map(result.captured_contexts, & &1.run_id)
      assert run_ids == ["stable-id", "stable-id", "stable-id"]
    end
  end

  # ===========================================================================
  # Tests: resume from mid-flow
  # ===========================================================================

  describe "resume from mid-flow" do
    test "can start from a node other than start_id" do
      flow = three_node_flow()

      # Skip node :a entirely, start from :b
      result = Pipeline.orchestrate(flow, :b, %{trail: [:already_done]})

      assert result.trail == [:already_done, :second, :third]
    end

    test "resume with middlewares fires for remaining nodes only" do
      flow = three_node_flow()

      result =
        Pipeline.orchestrate(flow, :b, %{trail: [:checkpointed]},
          middlewares: [TrackingMiddleware]
        )

      node_ids =
        result.mw_log
        |> Enum.filter(fn {dir, _, _} -> dir == :before end)
        |> Enum.map(fn {_, id, _} -> id end)

      # Only :b and :c — :a was skipped
      assert node_ids == [:b, :c]
    end
  end
end
