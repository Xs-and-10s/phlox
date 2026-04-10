defmodule Phlox.TypedTest do
  use ExUnit.Case, async: true

  alias Phlox.{Flow, Pipeline, HaltedError, Typed}

  # ===========================================================================
  # Test nodes — plain function specs (zero-dep, always works)
  # ===========================================================================

  defmodule StrictInputNode do
    @moduledoc "Requires :text and :language in shared"
    use Phlox.Node
    use Phlox.Typed

    input fn shared ->
      cond do
        not is_binary(Map.get(shared, :text)) ->
          {:error, ":text must be a binary"}
        not is_binary(Map.get(shared, :language)) ->
          {:error, ":language must be a binary"}
        true ->
          :ok
      end
    end

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :input_validated, true)}
    end
  end

  defmodule StrictOutputNode do
    @moduledoc "Requires :result in shared after running"
    use Phlox.Node
    use Phlox.Typed

    output fn shared ->
      if Map.has_key?(shared, :result),
        do: :ok,
        else: {:error, ":result must be present in shared"}
    end

    def post(shared, _prep, _exec, params) do
      if Map.get(params, :produce_result, true) do
        {:default, Map.put(shared, :result, "done")}
      else
        {:default, shared}
      end
    end
  end

  defmodule BothSpecsNode do
    @moduledoc "Has both input and output specs"
    use Phlox.Node
    use Phlox.Typed

    input fn shared ->
      if is_binary(Map.get(shared, :url)), do: :ok, else: {:error, "needs :url"}
    end

    output fn shared ->
      if is_binary(Map.get(shared, :body)), do: :ok, else: {:error, "needs :body"}
    end

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :body, "fetched content")}
    end
  end

  defmodule UntypedNode do
    @moduledoc "No specs — validation should be skipped"
    use Phlox.Node

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :untyped_ran, true)}
    end
  end

  defmodule ShapingNode do
    @moduledoc "Uses a function spec that returns {:ok, shaped}"
    use Phlox.Node
    use Phlox.Typed

    input fn shared ->
      # Trim the :name field as a shaping operation
      case Map.get(shared, :name) do
        name when is_binary(name) ->
          {:ok, Map.put(shared, :name, String.trim(name))}
        _ ->
          {:error, ":name must be a binary"}
      end
    end

    def post(shared, _prep, _exec, _params) do
      {:default, shared}
    end
  end

  defmodule InputOnlyNode do
    @moduledoc "Only has input spec"
    use Phlox.Node
    use Phlox.Typed

    input fn shared ->
      if Map.get(shared, :ready), do: :ok, else: {:error, "not ready"}
    end

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :processed, true)}
    end
  end

  defmodule OutputOnlyNode do
    @moduledoc "Only has output spec"
    use Phlox.Node
    use Phlox.Typed

    output fn shared ->
      if Map.get(shared, :processed), do: :ok, else: {:error, "not processed"}
    end

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :processed, true)}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp node_entry(id, module, params \\ %{}, successors \\ %{}) do
    {id, %{
      id: id,
      module: module,
      params: params,
      successors: successors,
      max_retries: 1,
      wait_ms: 0
    }}
  end

  defp single_flow(module, params \\ %{}) do
    {id, entry} = node_entry(:a, module, params)
    %Flow{start_id: id, nodes: %{id => entry}}
  end

  defp two_node_flow(mod_a, mod_b, params_a \\ %{}, params_b \\ %{}) do
    {_, a} = node_entry(:a, mod_a, params_a, %{"default" => :b})
    {_, b} = node_entry(:b, mod_b, params_b)
    %Flow{start_id: :a, nodes: %{a: a, b: b}}
  end

  defp run_validated(flow, shared, extra_mw \\ []) do
    Pipeline.orchestrate(flow, flow.start_id, shared,
      middlewares: extra_mw ++ [Phlox.Middleware.Validate]
    )
  end

  # ===========================================================================
  # Tests: Typed.read_spec
  # ===========================================================================

  describe "Typed.read_spec/2" do
    test "returns the input spec from a typed node" do
      spec = Typed.read_spec(StrictInputNode, :input)
      assert is_function(spec, 1)
    end

    test "returns the output spec from a typed node" do
      spec = Typed.read_spec(StrictOutputNode, :output)
      assert is_function(spec, 1)
    end

    test "returns nil for untyped nodes" do
      assert Typed.read_spec(UntypedNode, :input) == nil
      assert Typed.read_spec(UntypedNode, :output) == nil
    end

    test "returns nil for undeclared direction" do
      assert Typed.read_spec(InputOnlyNode, :output) == nil
      assert Typed.read_spec(OutputOnlyNode, :input) == nil
    end
  end

  # ===========================================================================
  # Tests: Typed.validate with plain functions
  # ===========================================================================

  describe "Typed.validate/2 with plain functions" do
    test "returns {:ok, value} on :ok" do
      spec = fn _v -> :ok end
      assert {:ok, %{x: 1}} = Typed.validate(%{x: 1}, spec)
    end

    test "returns {:ok, shaped} when function returns {:ok, shaped}" do
      spec = fn shared -> {:ok, Map.put(shared, :trimmed, true)} end
      assert {:ok, %{trimmed: true}} = Typed.validate(%{}, spec)
    end

    test "returns {:error, reason} on failure" do
      spec = fn _v -> {:error, "bad"} end
      assert {:error, "bad"} = Typed.validate(%{}, spec)
    end
  end

  # ===========================================================================
  # Tests: input validation via middleware
  # ===========================================================================

  describe "input validation" do
    test "passes when shared matches input spec" do
      flow = single_flow(StrictInputNode)
      result = run_validated(flow, %{text: "hello", language: "en"})
      assert result.input_validated == true
    end

    test "halts when shared violates input spec" do
      flow = single_flow(StrictInputNode)

      error = assert_raise HaltedError, fn ->
        run_validated(flow, %{text: 123, language: "en"})
      end

      assert error.phase == :before_node
      assert error.node_id == :a

      {:validation_error, :a, :input, msg} = error.reason
      assert msg =~ ":text must be a binary"
    end

    test "halts with missing required field" do
      flow = single_flow(StrictInputNode)

      error = assert_raise HaltedError, fn ->
        run_validated(flow, %{text: "hello"})
      end

      {:validation_error, :a, :input, msg} = error.reason
      assert msg =~ ":language"
    end
  end

  # ===========================================================================
  # Tests: output validation via middleware
  # ===========================================================================

  describe "output validation" do
    test "passes when post/4 produces correct shared" do
      flow = single_flow(StrictOutputNode, %{produce_result: true})
      result = run_validated(flow, %{})
      assert result.result == "done"
    end

    test "halts when post/4 produces invalid shared" do
      flow = single_flow(StrictOutputNode, %{produce_result: false})

      error = assert_raise HaltedError, fn ->
        run_validated(flow, %{})
      end

      assert error.phase == :after_node
      assert error.node_id == :a

      {:validation_error, :a, :output, msg} = error.reason
      assert msg =~ ":result"
    end
  end

  # ===========================================================================
  # Tests: both specs
  # ===========================================================================

  describe "both input and output specs" do
    test "validates both boundaries" do
      flow = single_flow(BothSpecsNode)
      result = run_validated(flow, %{url: "https://example.com"})
      assert result.body == "fetched content"
    end

    test "input failure prevents node execution" do
      flow = single_flow(BothSpecsNode)

      error = assert_raise HaltedError, fn ->
        run_validated(flow, %{url: 123})
      end

      {:validation_error, :a, :input, _} = error.reason
    end
  end

  # ===========================================================================
  # Tests: untyped nodes are skipped
  # ===========================================================================

  describe "untyped nodes" do
    test "validation is skipped — node runs normally" do
      flow = single_flow(UntypedNode)
      result = run_validated(flow, %{anything: :goes})
      assert result.untyped_ran == true
    end

    test "mixed typed and untyped nodes in same flow" do
      flow = two_node_flow(UntypedNode, StrictInputNode)
      result = run_validated(flow, %{text: "hello", language: "en"})
      assert result.untyped_ran == true
      assert result.input_validated == true
    end
  end

  # ===========================================================================
  # Tests: shaped values replace shared
  # ===========================================================================

  describe "shaped values" do
    test "input spec can shape shared before the node sees it" do
      flow = single_flow(ShapingNode)
      result = run_validated(flow, %{name: "  Mark  "})
      # The input spec trimmed :name before prep/2 ran
      assert result.name == "Mark"
    end
  end

  # ===========================================================================
  # Tests: partial specs (input-only, output-only)
  # ===========================================================================

  describe "partial specs" do
    test "input-only node validates input, skips output" do
      flow = single_flow(InputOnlyNode)
      result = run_validated(flow, %{ready: true})
      assert result.processed == true
    end

    test "input-only node halts on bad input" do
      flow = single_flow(InputOnlyNode)

      assert_raise HaltedError, fn ->
        run_validated(flow, %{ready: false})
      end
    end

    test "output-only node skips input, validates output" do
      flow = single_flow(OutputOnlyNode)
      result = run_validated(flow, %{})
      assert result.processed == true
    end
  end

  # ===========================================================================
  # Tests: multi-node flow with validation
  # ===========================================================================

  describe "multi-node validated flow" do
    test "validation fires at every node boundary" do
      # Node A: requires :url, produces :body
      # Node B: requires :body (via input spec), untyped output
      flow = two_node_flow(BothSpecsNode, StrictInputNode)

      # StrictInputNode needs :text and :language, but BothSpecsNode
      # doesn't produce those. So let's set up a flow that works:
      {_, a} = node_entry(:a, BothSpecsNode, %{}, %{"default" => :b})
      {_, b} = node_entry(:b, UntypedNode, %{})
      flow = %Flow{start_id: :a, nodes: %{a: a, b: b}}

      result = run_validated(flow, %{url: "https://x.com"})
      assert result.body == "fetched content"
      assert result.untyped_ran == true
    end

    test "second node's input validation catches first node's bad output" do
      # Node A: untyped, doesn't produce :text
      # Node B: requires :text in input
      flow = two_node_flow(UntypedNode, StrictInputNode)

      error = assert_raise HaltedError, fn ->
        run_validated(flow, %{})
      end

      # Fails at node :b's input validation
      assert error.node_id == :b
      {:validation_error, :b, :input, _} = error.reason
    end
  end

  # ===========================================================================
  # Tests: validate middleware composes with other middlewares
  # ===========================================================================

  describe "composition with other middlewares" do
    defmodule CountMiddleware do
      @behaviour Phlox.Middleware
      @impl true
      def before_node(shared, _ctx) do
        count = Map.get(shared, :mw_count, 0)
        {:cont, Map.put(shared, :mw_count, count + 1)}
      end
    end

    test "validate runs alongside other middlewares" do
      flow = single_flow(InputOnlyNode)

      result = Pipeline.orchestrate(flow, flow.start_id, %{ready: true},
        middlewares: [CountMiddleware, Phlox.Middleware.Validate]
      )

      assert result.mw_count == 1
      assert result.processed == true
    end

    test "validate halts before other middlewares' after_node" do
      flow = single_flow(StrictInputNode)

      error = assert_raise HaltedError, fn ->
        Pipeline.orchestrate(flow, flow.start_id, %{text: 123},
          middlewares: [CountMiddleware, Phlox.Middleware.Validate]
        )
      end

      # CountMiddleware's before_node ran (it's first in list),
      # then Validate's before_node halted
      assert error.middleware == Phlox.Middleware.Validate
    end
  end

  # ===========================================================================
  # Tests: Gladius integration (conditional — only runs if Gladius is loaded)
  # ===========================================================================

  if Code.ensure_loaded?(Gladius) do
    defmodule GladiusInputNode do
      use Phlox.Node
      use Phlox.Typed

      import Gladius

      input open_schema(%{
        required(:text)     => string(:filled?),
        required(:language) => string(:filled?)
      })

      def post(shared, _prep, _exec, _params) do
        {:default, Map.put(shared, :gladius_validated, true)}
      end
    end

    defmodule GladiusTransformNode do
      use Phlox.Node
      use Phlox.Typed

      import Gladius

      input open_schema(%{
        required(:name) => transform(string(:filled?), &String.trim/1)
      })

      def post(shared, _prep, _exec, _params) do
        {:default, shared}
      end
    end

    describe "Gladius integration" do
      test "validates shared against a Gladius schema" do
        flow = single_flow(GladiusInputNode)
        result = run_validated(flow, %{text: "hello", language: "en"})
        assert result.gladius_validated == true
      end

      test "halts on Gladius validation failure" do
        flow = single_flow(GladiusInputNode)

        error = assert_raise HaltedError, fn ->
          run_validated(flow, %{text: "", language: "en"})
        end

        {:validation_error, :a, :input, errors} = error.reason
        assert is_list(errors)
      end

      test "Gladius transforms shape shared before the node runs" do
        flow = single_flow(GladiusTransformNode)
        result = run_validated(flow, %{name: "  Mark  "})
        assert result.name == "Mark"
      end
    end
  end
end
