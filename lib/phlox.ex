# top-level convenience (run/2, graph/0)

defmodule Phlox do
  @moduledoc """
  Phlox — a lightweight, OTP-ready graph execution framework for AI agent pipelines.

  Phlox is an Elixir port of [PocketFlow](https://github.com/The-Pocket/PocketFlow),
  redesigned around Elixir idioms: explicit data threading, behaviour-based nodes,
  and a pure orchestration loop built for GenServer wrapping.

  ## Quick start

      # 1. Define nodes
      defmodule FetchNode do
        use Phlox.Node

        def prep(shared, _params), do: Map.fetch!(shared, :url)
        def exec(url, _params), do: HTTPoison.get!(url).body
        def post(shared, _prep, body, _params), do: {:default, Map.put(shared, :body, body)}
      end

      defmodule SummariseNode do
        use Phlox.Node

        def prep(shared, _params), do: Map.fetch!(shared, :body)
        def exec(body, params), do: MyLLM.call(body, params.prompt)
        def post(shared, _prep, summary, _params), do: {:default, Map.put(shared, :summary, summary)}
      end

      # 2. Wire them into a flow
      flow =
        Phlox.graph()
        |> Phlox.Graph.add_node(:fetch,     FetchNode,     %{})
        |> Phlox.Graph.add_node(:summarise, SummariseNode, %{prompt: "tl;dr"})
        |> Phlox.Graph.connect(:fetch, :summarise)
        |> Phlox.Graph.start_at(:fetch)
        |> Phlox.Graph.to_flow!()

      # 3. Run it
      {:ok, result} = Phlox.run(flow, %{url: "https://example.com"})
      IO.inspect(result.summary)

  See `Phlox.Node`, `Phlox.BatchNode`, `Phlox.Graph`, `Phlox.Flow`, and
  `Phlox.BatchFlow` for full documentation.
  """

  alias Phlox.{Graph, Flow}

  @doc "Shortcut for `Phlox.Flow.run/2`."
  defdelegate run(flow, shared \\ %{}), to: Flow

  @doc "Shortcut for `Phlox.Graph.new/0`."
  defdelegate graph(), to: Graph, as: :new
end
