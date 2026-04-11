# pipeable builder → validated %Flow{}

defmodule Phlox.Graph do
  @moduledoc """
  Pipeable builder API for constructing `Phlox.Flow` graphs.

  ## Example

      alias Phlox.Graph

      flow =
        Graph.new()
        |> Graph.add_node(:fetch, MyApp.FetchNode, %{url: "https://api.example.com"}, max_retries: 3)
        |> Graph.add_node(:parse, MyApp.ParseNode, %{schema: :json})
        |> Graph.add_node(:store, MyApp.StoreNode, %{})
        |> Graph.add_node(:error, MyApp.ErrorNode, %{})
        |> Graph.connect(:fetch, :parse)
        |> Graph.connect(:fetch, :error, action: "error")
        |> Graph.connect(:parse, :store)
        |> Graph.start_at(:fetch)
        |> Graph.to_flow()

  `to_flow/1` validates the graph (no unknown node references, start node exists)
  and returns `{:ok, %Phlox.Flow{}}` or `{:error, reasons}`.
  Use `to_flow!/1` to get the flow directly, raising on validation failure.
  """

  alias Phlox.Flow

  # Internal builder accumulator — not exposed to users
  @type builder :: %__MODULE__.Builder{}

  defmodule Builder do
    @moduledoc false
    defstruct nodes: %{}, start_id: nil
  end

  @doc "Start a new graph builder."
  @spec new() :: Builder.t()
  def new(), do: %Builder{}

  @doc """
  Add a node to the graph.

  - `id`      — unique atom identifier for this node in the graph
  - `module`  — a module that implements `Phlox.Node` or `Phlox.BatchNode`
  - `params`  — node-specific configuration, immutable per run
  - `opts`    — keyword options:
      - `max_retries:` (default 0 — one attempt, no retries).
        Number of retries *after* the first attempt.
        Use `:infinity` for unlimited retries (pair with `:wait_ms`).
      - `wait_ms:` (default 0)
  """
  @spec add_node(Builder.t(), atom(), module(), map(), keyword()) :: Builder.t()
  def add_node(%Builder{} = b, id, module, params \\ %{}, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 0)
    validate_max_retries!(max_retries)

    entry = %{
      id: id,
      module: module,
      params: params,
      successors: %{},
      max_retries: max_retries,
      wait_ms: Keyword.get(opts, :wait_ms, 0)
    }

    %Builder{b | nodes: Map.put(b.nodes, id, entry)}
  end

  defp validate_max_retries!(:infinity), do: :ok
  defp validate_max_retries!(n) when is_integer(n) and n >= 0, do: :ok

  defp validate_max_retries!(n) do
    raise ArgumentError,
          "Phlox.Graph.add_node: max_retries must be a non-negative integer or :infinity, got: #{inspect(n)}"
  end

  @doc """
  Connect two nodes. `action` defaults to `"default"`.

  Warns if you overwrite an existing connection for the same action —
  same behaviour as PocketFlow's Python original.
  """
  @spec connect(Builder.t(), atom(), atom(), keyword()) :: Builder.t()
  def connect(%Builder{} = b, from_id, to_id, opts \\ []) do
    action = Keyword.get(opts, :action, "default")

    updated_nodes =
      Map.update!(b.nodes, from_id, fn node ->
        if Map.has_key?(node.successors, action) do
          IO.warn(
            "Phlox.Graph: overwriting successor for action '#{action}' on node :#{from_id}",
            []
          )
        end

        %{node | successors: Map.put(node.successors, action, to_id)}
      end)

    %Builder{b | nodes: updated_nodes}
  end

  @doc "Set the entry-point node for this graph."
  @spec start_at(Builder.t(), atom()) :: Builder.t()
  def start_at(%Builder{} = b, id), do: %Builder{b | start_id: id}

  @doc """
  Validate the graph and return `{:ok, %Phlox.Flow{}}` or `{:error, [reason]}`.
  """
  @spec to_flow(Builder.t()) :: {:ok, Flow.t()} | {:error, [String.t()]}
  def to_flow(%Builder{} = b) do
    case validate(b) do
      [] -> {:ok, %Flow{start_id: b.start_id, nodes: b.nodes}}
      errors -> {:error, errors}
    end
  end

  @doc """
  Like `to_flow/1` but raises `ArgumentError` on validation failure.
  """
  @spec to_flow!(Builder.t()) :: Flow.t()
  def to_flow!(%Builder{} = b) do
    case to_flow(b) do
      {:ok, flow} -> flow
      {:error, reasons} -> raise ArgumentError, "Invalid Phlox graph:\n" <> Enum.join(reasons, "\n")
    end
  end

  # --- private ---

  defp validate(%Builder{nodes: nodes, start_id: start_id}) do
    known = Map.keys(nodes)

    start_errors =
      cond do
        is_nil(start_id) -> ["No start node set. Call Graph.start_at/2."]
        start_id not in known -> ["Start node :#{start_id} is not in the graph."]
        true -> []
      end

    successor_errors =
      for {from_id, node} <- nodes,
          {action, to_id} <- node.successors,
          to_id not in known do
        "Node :#{from_id} has successor :#{to_id} for action '#{action}', but :#{to_id} is not in the graph."
      end

    start_errors ++ successor_errors
  end
end
