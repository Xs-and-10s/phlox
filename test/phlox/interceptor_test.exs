defmodule Phlox.InterceptorTest do
  use ExUnit.Case, async: true

  alias Phlox.{Flow, Pipeline, HaltedError}

  # ===========================================================================
  # Test interceptors
  # ===========================================================================

  defmodule TrackingInterceptor do
    @moduledoc "Records before/after calls into shared via prep_res threading"
    @behaviour Phlox.Interceptor

    @impl true
    def before_exec(prep_res, ctx) do
      entry = {:before_exec, ctx.node_id, ctx.interceptor_opts}
      log = Map.get(prep_res, :interceptor_log, [])
      {:cont, Map.put(prep_res, :interceptor_log, log ++ [entry])}
    end

    @impl true
    def after_exec(exec_res, ctx) do
      entry = {:after_exec, ctx.node_id, ctx.interceptor_opts}
      log = Map.get(exec_res, :interceptor_log, [])
      {:cont, Map.put(exec_res, :interceptor_log, log ++ [entry])}
    end
  end

  defmodule SecondTracker do
    @behaviour Phlox.Interceptor

    @impl true
    def before_exec(prep_res, ctx) do
      entry = {:before_exec, ctx.node_id, :second}
      log = Map.get(prep_res, :interceptor_log, [])
      {:cont, Map.put(prep_res, :interceptor_log, log ++ [entry])}
    end

    @impl true
    def after_exec(exec_res, ctx) do
      entry = {:after_exec, ctx.node_id, :second}
      log = Map.get(exec_res, :interceptor_log, [])
      {:cont, Map.put(exec_res, :interceptor_log, log ++ [entry])}
    end
  end

  defmodule CacheInterceptor do
    @moduledoc "Simulates a cache hit — skips exec entirely"
    @behaviour Phlox.Interceptor

    @impl true
    def before_exec(_prep_res, ctx) do
      if ctx.interceptor_opts[:force_hit] do
        {:skip, %{cached: true, value: ctx.interceptor_opts[:cached_value]}}
      else
        {:cont, _prep_res}
      end
    end
  end

  defmodule HaltingInterceptor do
    @behaviour Phlox.Interceptor

    @impl true
    def before_exec(_prep_res, _ctx) do
      {:halt, :rate_limited}
    end
  end

  defmodule AfterHaltInterceptor do
    @behaviour Phlox.Interceptor

    @impl true
    def after_exec(_exec_res, _ctx) do
      {:halt, :output_rejected}
    end
  end

  defmodule BeforeOnlyInterceptor do
    @behaviour Phlox.Interceptor

    @impl true
    def before_exec(prep_res, _ctx) do
      {:cont, Map.put(prep_res, :before_only, true)}
    end
  end

  defmodule AfterOnlyInterceptor do
    @behaviour Phlox.Interceptor

    @impl true
    def after_exec(exec_res, _ctx) do
      {:cont, Map.put(exec_res, :after_only, true)}
    end
  end

  # ===========================================================================
  # Test nodes with interceptors
  # ===========================================================================

  defmodule TrackedNode do
    use Phlox.Node

    intercept TrackingInterceptor, label: :first

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: prep_res
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  defmodule DoubleTrackedNode do
    use Phlox.Node

    intercept TrackingInterceptor, label: :first
    intercept SecondTracker

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: prep_res
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  defmodule CachedNode do
    use Phlox.Node

    intercept CacheInterceptor, force_hit: true, cached_value: "from cache"

    def prep(shared, _p), do: shared
    def exec(_prep, _p), do: raise("should not be called — cache should skip")
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  defmodule CacheMissNode do
    use Phlox.Node

    intercept CacheInterceptor, force_hit: false

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: Map.put(prep_res, :computed, true)
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  defmodule HaltedNode do
    use Phlox.Node

    intercept HaltingInterceptor

    def prep(shared, _p), do: shared
    def exec(_prep, _p), do: raise("should not be called")
    def post(shared, _p, _e, _p2), do: {:default, shared}
  end

  defmodule AfterHaltedNode do
    use Phlox.Node

    intercept AfterHaltInterceptor

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: prep_res
    def post(shared, _p, _e, _p2), do: {:default, shared}
  end

  defmodule PlainNode do
    @moduledoc "No interceptors"
    use Phlox.Node

    def post(shared, _p, _e, _p2), do: {:default, Map.put(shared, :plain, true)}
  end

  defmodule BeforeOnlyNode do
    use Phlox.Node

    intercept BeforeOnlyInterceptor

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: prep_res
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  defmodule AfterOnlyNode do
    use Phlox.Node

    intercept AfterOnlyInterceptor

    def prep(shared, _p), do: shared
    def exec(prep_res, _p), do: prep_res
    def post(_shared, _p, exec_res, _p2), do: {:default, exec_res}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp single_flow(module) do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{id: :a, module: module, params: %{},
             successors: %{}, max_retries: 1, wait_ms: 0}
      }
    }
  end

  defp two_node_flow(mod_a, mod_b) do
    %Flow{
      start_id: :a,
      nodes: %{
        a: %{id: :a, module: mod_a, params: %{},
             successors: %{"default" => :b}, max_retries: 1, wait_ms: 0},
        b: %{id: :b, module: mod_b, params: %{},
             successors: %{}, max_retries: 1, wait_ms: 0}
      }
    }
  end

  # ===========================================================================
  # Tests: read_interceptors
  # ===========================================================================

  describe "Interceptor.read_interceptors/1" do
    test "returns declared interceptors" do
      interceptors = Phlox.Interceptor.read_interceptors(TrackedNode)
      assert [{TrackingInterceptor, [label: :first]}] = interceptors
    end

    test "returns multiple interceptors in declaration order" do
      interceptors = Phlox.Interceptor.read_interceptors(DoubleTrackedNode)
      assert [{TrackingInterceptor, [label: :first]}, {SecondTracker, []}] = interceptors
    end

    test "returns empty list for nodes without interceptors" do
      assert [] = Phlox.Interceptor.read_interceptors(PlainNode)
    end
  end

  # ===========================================================================
  # Tests: interceptor execution via Pipeline
  # ===========================================================================

  describe "interceptor execution" do
    test "before_exec and after_exec fire around exec" do
      flow = single_flow(TrackedNode)
      result = Pipeline.orchestrate(flow, :a, %{})

      log = result.interceptor_log
      assert [{:before_exec, :a, _}, {:after_exec, :a, _}] = log
    end

    test "interceptor opts are passed through context" do
      flow = single_flow(TrackedNode)
      result = Pipeline.orchestrate(flow, :a, %{})

      [{:before_exec, :a, opts}, _] = result.interceptor_log
      assert opts == [label: :first]
    end

    test "multiple interceptors execute in onion order" do
      flow = single_flow(DoubleTrackedNode)
      result = Pipeline.orchestrate(flow, :a, %{})

      log = result.interceptor_log
      assert [
        {:before_exec, :a, [label: :first]},
        {:before_exec, :a, :second},
        {:after_exec, :a, :second},
        {:after_exec, :a, [label: :first]}
      ] = log
    end
  end

  # ===========================================================================
  # Tests: skip (cache hit)
  # ===========================================================================

  describe "skip (cache hit)" do
    test "before_exec :skip bypasses exec entirely" do
      flow = single_flow(CachedNode)
      result = Pipeline.orchestrate(flow, :a, %{})

      assert result.cached == true
      assert result.value == "from cache"
    end

    test "cache miss falls through to exec" do
      flow = single_flow(CacheMissNode)
      result = Pipeline.orchestrate(flow, :a, %{})

      assert result.computed == true
    end
  end

  # ===========================================================================
  # Tests: halt
  # ===========================================================================

  describe "halt" do
    test "before_exec halt raises HaltedError" do
      flow = single_flow(HaltedNode)

      error = assert_raise HaltedError, fn ->
        Pipeline.orchestrate(flow, :a, %{})
      end

      assert error.reason == :rate_limited
      assert error.node_id == :a
      assert error.phase == :before_exec
    end

    test "after_exec halt raises HaltedError" do
      flow = single_flow(AfterHaltedNode)

      error = assert_raise HaltedError, fn ->
        Pipeline.orchestrate(flow, :a, %{})
      end

      assert error.reason == :output_rejected
      assert error.node_id == :a
      assert error.phase == :after_exec
    end
  end

  # ===========================================================================
  # Tests: partial interceptors
  # ===========================================================================

  describe "partial interceptors" do
    test "before-only interceptor works" do
      flow = single_flow(BeforeOnlyNode)
      result = Pipeline.orchestrate(flow, :a, %{})
      assert result.before_only == true
    end

    test "after-only interceptor works" do
      flow = single_flow(AfterOnlyNode)
      result = Pipeline.orchestrate(flow, :a, %{})
      assert result.after_only == true
    end
  end

  # ===========================================================================
  # Tests: nodes without interceptors are unaffected
  # ===========================================================================

  describe "no interceptors" do
    test "plain nodes work as before" do
      flow = single_flow(PlainNode)
      result = Pipeline.orchestrate(flow, :a, %{})
      assert result.plain == true
    end

    test "mixed intercepted and plain nodes in same flow" do
      flow = two_node_flow(TrackedNode, PlainNode)
      result = Pipeline.orchestrate(flow, :a, %{})
      assert result.plain == true
      assert is_list(result.interceptor_log)
    end
  end

  # ===========================================================================
  # Tests: interceptors compose with middleware
  # ===========================================================================

  describe "interceptors + middleware composition" do
    defmodule TagMiddleware do
      @behaviour Phlox.Middleware
      @impl true
      def after_node(shared, action, _ctx) do
        {:cont, Map.put(shared, :mw_tagged, true), action}
      end
    end

    test "middleware and interceptors both fire" do
      flow = single_flow(TrackedNode)

      result = Pipeline.orchestrate(flow, :a, %{},
        middlewares: [TagMiddleware]
      )

      assert result.mw_tagged == true
      assert is_list(result.interceptor_log)
    end
  end

  # ===========================================================================
  # Tests: Interceptor.wrap/4
  # ===========================================================================

  describe "Interceptor.wrap/4" do
    test "empty interceptor list returns direct exec function" do
      defmodule DirectExecNode do
        use Phlox.Node
        def exec(prep_res, _p), do: {:executed, prep_res}
      end

      exec_fn = Phlox.Interceptor.wrap(DirectExecNode, :test, %{}, [])
      assert {:executed, :input} = exec_fn.(:input)
    end
  end
end
