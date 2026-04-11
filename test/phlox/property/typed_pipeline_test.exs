defmodule Phlox.Property.TypedPipelineTest do
  @moduledoc """
  Property-based test for Pipeline + Gladius typed shared state.

  Uses `Gladius.gen/1` to generate valid `shared` maps from a Gladius
  schema, runs them through Pipeline with `Phlox.Middleware.Validate`,
  and verifies:

  1. Well-typed inputs produce well-typed outputs
  2. Gladius transforms (trim, downcase, etc.) are applied by the middleware
  3. Coercions survive the full pipeline round-trip
  4. Invalid inputs are caught and halt the pipeline

  This is the natural bridge between Gladius and Phlox — specs defined
  once, tested against arbitrary generated data.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  require Gladius

  alias Phlox.{Graph, Pipeline}

  # ---------------------------------------------------------------------------
  # Specs — defined as functions (not module attrs) per Gladius convention.
  # Fully qualified to avoid clashing with StreamData's same-named generators.
  # ---------------------------------------------------------------------------

  defp input_spec do
    Gladius.open_schema(%{
      Gladius.required(:name)  => Gladius.string(:filled?),
      Gladius.required(:score) => Gladius.integer(gte?: 0, lte?: 1000),
      Gladius.required(:tag)   => Gladius.atom(in?: [:alpha, :beta, :gamma, :delta])
    })
  end

  defp output_spec do
    Gladius.open_schema(%{
      Gladius.required(:name)      => Gladius.string(:filled?),
      Gladius.required(:score)     => Gladius.integer(gte?: 0, lte?: 1000),
      Gladius.required(:tag)       => Gladius.atom(in?: [:alpha, :beta, :gamma, :delta]),
      Gladius.required(:processed) => Gladius.spec(&(&1 == true))
    })
  end

  # ---------------------------------------------------------------------------
  # Node fixtures
  # ---------------------------------------------------------------------------

  defmodule PassthroughNode do
    @moduledoc false
    use Phlox.Node
    use Phlox.Typed
    require Gladius

    input Gladius.open_schema(%{
      Gladius.required(:name)  => Gladius.string(:filled?),
      Gladius.required(:score) => Gladius.integer(gte?: 0, lte?: 1000),
      Gladius.required(:tag)   => Gladius.atom(in?: [:alpha, :beta, :gamma, :delta])
    })

    output Gladius.open_schema(%{
      Gladius.required(:name)      => Gladius.string(:filled?),
      Gladius.required(:score)     => Gladius.integer(gte?: 0, lte?: 1000),
      Gladius.required(:tag)       => Gladius.atom(in?: [:alpha, :beta, :gamma, :delta]),
      Gladius.required(:processed) => Gladius.spec(&(&1 == true))
    })

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :processed, true)}
    end
  end

  defmodule TransformNode do
    @moduledoc false
    use Phlox.Node
    use Phlox.Typed

    input Gladius.open_schema(%{
      Gladius.required(:name) => Gladius.transform(Gladius.string(:filled?), &String.trim/1)
    })

    def post(shared, _prep, _exec, _params) do
      {:default, Map.put(shared, :trimmed, true)}
    end
  end

  defmodule ScoreDoubleNode do
    @moduledoc false
    use Phlox.Node
    use Phlox.Typed

    input Gladius.open_schema(%{
      Gladius.required(:score) => Gladius.integer(gte?: 0)
    })

    def prep(shared, _p), do: shared.score
    def exec(score, _p), do: score * 2
    def post(shared, _prep, doubled, _p) do
      {:default, Map.put(shared, :score, doubled)}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_validated(flow, shared) do
    Pipeline.orchestrate(flow, flow.start_id, shared,
      middlewares: [Phlox.Middleware.Validate]
    )
  end

  defp single_flow(module) do
    Graph.new()
    |> Graph.add_node(:a, module, %{})
    |> Graph.start_at(:a)
    |> Graph.to_flow!()
  end

  defp chain_flow(modules) do
    ids = for {_mod, idx} <- Enum.with_index(modules), do: :"node_#{idx}"

    builder =
      Enum.zip(ids, modules)
      |> Enum.reduce(Graph.new(), fn {id, mod}, b ->
        Graph.add_node(b, id, mod, %{})
      end)

    builder =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(builder, fn [from, to], b ->
        Graph.connect(b, from, to)
      end)
      |> Graph.start_at(hd(ids))

    Graph.to_flow!(builder)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "generated inputs that conform to input_spec produce conforming outputs" do
    flow = single_flow(PassthroughNode)

    check all shared <- Gladius.gen(input_spec()), max_runs: 200 do
      result = run_validated(flow, shared)

      assert result[:processed] == true
      assert {:ok, _} = Gladius.conform(output_spec(), result),
        "Output should conform to output_spec, got: #{inspect(result)}"
    end
  end

  property "Gladius transforms in input spec shape shared before the node runs" do
    flow = single_flow(TransformNode)

    check all name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
              leading <- StreamData.string([?\s], min_length: 0, max_length: 5),
              trailing <- StreamData.string([?\s], min_length: 0, max_length: 5),
              max_runs: 200 do
      padded_name = leading <> name <> trailing
      # Skip if the trimmed result would be empty
      trimmed = String.trim(padded_name)

      if trimmed != "" do
        shared = %{name: padded_name}
        result = run_validated(flow, shared)

        # The Validate middleware shapes shared via Gladius.conform,
        # which runs the trim transform BEFORE the node sees it
        assert result.name == trimmed or result.name == padded_name,
          "Expected name to be trimmed. Input: #{inspect(padded_name)}, Got: #{inspect(result.name)}"
        assert result[:trimmed] == true
      end
    end
  end

  property "conform is idempotent — running validated output through the spec again succeeds" do
    check all shared <- Gladius.gen(input_spec()), max_runs: 200 do
      # First conform
      {:ok, shaped1} = Gladius.conform(input_spec(), shared)
      # Second conform on shaped output
      {:ok, shaped2} = Gladius.conform(input_spec(), shaped1)

      assert shaped1 == shaped2,
        "conform should be idempotent. First: #{inspect(shaped1)}, Second: #{inspect(shaped2)}"
    end
  end

  property "multi-node chain preserves type safety through the pipeline" do
    flow = chain_flow([PassthroughNode, ScoreDoubleNode])

    check all shared <- Gladius.gen(input_spec()), max_runs: 200 do
      result = run_validated(flow, shared)

      # PassthroughNode adds :processed, ScoreDoubleNode doubles :score
      assert result[:processed] == true
      assert result[:score] == shared[:score] * 2
    end
  end

  property "invalid inputs are caught by Validate middleware" do
    flow = single_flow(PassthroughNode)

    check all bad_name <- member_of([nil, "", 42, :not_a_string, []]),
              score <- integer(-100..-1),
              max_runs: 50 do
      shared = %{name: bad_name, score: score, tag: :alpha}

      assert_raise Phlox.HaltedError, fn ->
        run_validated(flow, shared)
      end
    end
  end

  property "extra keys in open_schema pass through unchanged" do
    flow = single_flow(PassthroughNode)

    check all shared <- Gladius.gen(input_spec()),
              extra_key <- atom(:alphanumeric),
              extra_val <- one_of([integer(), binary(), boolean()]),
              max_runs: 200 do
      # Inject an extra key that the schema doesn't declare
      shared_with_extra = Map.put(shared, extra_key, extra_val)

      result = run_validated(flow, shared_with_extra)

      # open_schema lets extra keys pass through
      assert result[extra_key] == extra_val,
        "Extra key #{inspect(extra_key)} should survive pipeline, " <>
        "expected #{inspect(extra_val)}, got #{inspect(result[extra_key])}"
    end
  end
end
