defmodule Phlox.DSLTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Node fixtures
  # ---------------------------------------------------------------------------

  defmodule IncrNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.get(shared, :count, 0)
    def exec(n, _p), do: n + 1
    def post(shared, _p, n, _p2), do: {:default, Map.put(shared, :count, n)}
  end

  defmodule TagNode do
    use Phlox.Node
    def post(shared, _p, _e, params) do
      {:default, Map.put(shared, :tag, params.tag)}
    end
  end

  defmodule BranchNode do
    use Phlox.Node
    def prep(shared, _p), do: Map.get(shared, :count, 0)
    def exec(n, _p), do: n
    def post(shared, _p, n, _p2) when n >= 3, do: {"done", shared}
    def post(shared, _p, _n, _p2),             do: {"again", shared}
  end

  defmodule ErrorNode do
    use Phlox.Node
    def post(shared, _p, _e, _p2), do: {:default, Map.put(shared, :errored, true)}
  end

  # ---------------------------------------------------------------------------
  # DSL flow definitions — defined at module level, not inside tests
  # ---------------------------------------------------------------------------

  defmodule LinearFlow do
    use Phlox.DSL

    node :incr, IncrNode, %{}
    node :tag,  TagNode,  %{tag: :done}

    connect :incr, :tag
    start_at :incr
  end

  defmodule BranchFlow do
    use Phlox.DSL

    node :incr,   IncrNode,  %{}
    node :branch, BranchNode, %{}
    node :tag,    TagNode,    %{tag: :finished}

    connect :incr, :branch
    connect :branch, :incr, action: "again"
    connect :branch, :tag,  action: "done"
    start_at :incr
  end

  defmodule RetryFlow do
    use Phlox.DSL

    node :incr, IncrNode, %{}, max_retries: 5, wait_ms: 0
    start_at :incr
  end

  defmodule MultiErrorFlow do
    use Phlox.DSL

    node :incr,  IncrNode,  %{}
    node :error, ErrorNode, %{}

    connect :incr, :error, action: "error"
    # no default from :incr — flow ends after :incr on :default
    start_at :incr
  end

  # ---------------------------------------------------------------------------
  # flow/0
  # ---------------------------------------------------------------------------

  test "flow/0 returns a valid %Phlox.Flow{}" do
    flow = LinearFlow.flow()
    assert %Phlox.Flow{} = flow
    assert flow.start_id == :incr
    assert Map.has_key?(flow.nodes, :incr)
    assert Map.has_key?(flow.nodes, :tag)
  end

  test "flow/0 can be called multiple times and returns equivalent structs" do
    assert LinearFlow.flow() == LinearFlow.flow()
  end

  test "flow/0 captures node params" do
    flow = LinearFlow.flow()
    assert flow.nodes[:tag].params == %{tag: :done}
  end

  test "flow/0 captures node opts" do
    flow = RetryFlow.flow()
    assert flow.nodes[:incr].max_retries == 5
    assert flow.nodes[:incr].wait_ms == 0
  end

  test "flow/0 captures connections" do
    flow = BranchFlow.flow()
    assert flow.nodes[:branch].successors["again"] == :incr
    assert flow.nodes[:branch].successors["done"]  == :tag
  end

  # ---------------------------------------------------------------------------
  # run/1
  # ---------------------------------------------------------------------------

  test "run/0 uses empty shared by default" do
    assert {:ok, %{count: 1, tag: :done}} = LinearFlow.run()
  end

  test "run/1 passes shared to the flow" do
    assert {:ok, %{count: 2, tag: :done}} = LinearFlow.run(%{count: 1})
  end

  test "run/1 handles a branching loop" do
    # BranchFlow increments until count >= 3, then tags :finished
    assert {:ok, %{count: 3, tag: :finished}} = BranchFlow.run()
  end

  test "run/1 returns {:error, _} on node failure" do
    defmodule BoomFlow do
      use Phlox.DSL

      defmodule BoomNode do
        use Phlox.Node
        def exec(_p, _p2), do: raise "boom"
      end

      node :boom, BoomNode, %{}, max_retries: 1
      start_at :boom
    end

    assert {:error, %RuntimeError{}} = BoomFlow.run()
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  test "flow/0 raises ArgumentError for missing start node" do
    defmodule NoStartFlow do
      use Phlox.DSL
      node :a, IncrNode, %{}
      # no start_at
    end

    assert_raise ArgumentError, ~r/Invalid Phlox graph/, fn ->
      NoStartFlow.flow()
    end
  end

  test "flow/0 raises ArgumentError for unknown successor" do
    defmodule BadSuccessorFlow do
      use Phlox.DSL
      node :a, IncrNode, %{}
      connect :a, :ghost
      start_at :a
    end

    assert_raise ArgumentError, ~r/ghost/, fn ->
      BadSuccessorFlow.flow()
    end
  end

  # ---------------------------------------------------------------------------
  # Interop with FlowSupervisor
  # ---------------------------------------------------------------------------

  test "DSL flow can be started under FlowSupervisor" do
    name = :"dsl_flow_#{System.unique_integer([:positive])}"
    {:ok, _} = Phlox.FlowSupervisor.start_flow(name, LinearFlow.flow(), %{})
    server   = Phlox.FlowSupervisor.server(name)

    assert {:ok, %{count: 1, tag: :done}} = Phlox.FlowServer.run(server)
    Phlox.FlowSupervisor.stop_flow(name)
  end
end
