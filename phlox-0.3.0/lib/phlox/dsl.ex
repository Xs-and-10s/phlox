defmodule Phlox.DSL do
  @moduledoc ~S"""
  Declarative macro DSL for defining Phlox flows as modules.

  Instead of building a flow imperatively with `Phlox.Graph`, declare it as
  a module. The module gains a `flow/0` function returning a validated
  `%Phlox.Flow{}`, and a `run/1` shortcut.

  ## Usage

      defmodule MyApp.IngestFlow do
        use Phlox.DSL

        node :fetch,  MyApp.FetchNode,  %{},              max_retries: 3
        node :parse,  MyApp.ParseNode,  %{schema: :json}
        node :store,  MyApp.StoreNode,  %{}
        node :error,  MyApp.ErrorNode,  %{}

        connect :fetch, :parse
        connect :fetch, :error,  action: "error"
        connect :parse, :store
        connect :parse, :error,  action: "error"

        start_at :fetch
      end

      # Shortcut run:
      {:ok, result} = MyApp.IngestFlow.run(%{url: "https://example.com"})

      # Get the flow struct for composition with FlowSupervisor:
      flow = MyApp.IngestFlow.flow()
      Phlox.FlowSupervisor.start_flow(:ingest, flow, shared)

  ## Generated functions

  - `flow/0`  — builds and returns a validated `%Phlox.Flow{}`; raises on
    invalid graph. The graph is rebuilt on each call; cache in a module
    attribute if you need a compile-time constant:

        @my_flow MyApp.IngestFlow.flow()

  - `run/1`   — `Phlox.run(flow(), shared)`; `shared` defaults to `%{}`.
  """

  defmacro __using__(_opts) do
    quote do
      import Phlox.DSL, only: [node: 2, node: 3, node: 4, connect: 2, connect: 3, start_at: 1]

      Module.register_attribute(__MODULE__, :phlox_nodes,      accumulate: true)
      Module.register_attribute(__MODULE__, :phlox_connections, accumulate: true)
      Module.register_attribute(__MODULE__, :phlox_start_id,   accumulate: false)

      @before_compile Phlox.DSL
    end
  end

  @doc """
  Declare a node. `params` defaults to `%{}`, `opts` defaults to `[]`.

      node :fetch, MyApp.FetchNode, %{url: "..."}, max_retries: 3, wait_ms: 500
  """
  defmacro node(id, module, params \\ quote(do: %{}), opts \\ []) do
    quote do
      @phlox_nodes {unquote(id), unquote(module), unquote(params), unquote(opts)}
    end
  end

  @doc """
  Declare a directed edge.

      connect :fetch, :parse                    # default action
      connect :fetch, :error, action: "error"
  """
  defmacro connect(from, to, opts \\ []) do
    quote do
      @phlox_connections {unquote(from), unquote(to), unquote(opts)}
    end
  end

  @doc "Set the entry-point node."
  defmacro start_at(id) do
    quote do
      @phlox_start_id unquote(id)
    end
  end

  defmacro __before_compile__(env) do
    raw_nodes       = Module.get_attribute(env.module, :phlox_nodes)      |> Enum.reverse()
    raw_connections = Module.get_attribute(env.module, :phlox_connections) |> Enum.reverse()
    start_id        = Module.get_attribute(env.module, :phlox_start_id)

    # Macro.escape/1 converts Elixir values (maps, keyword lists, tuples) into
    # safe AST representations that can be injected via unquote into a quote block.
    # Without it, %{} and keyword lists cause "not a valid AST node" errors.
    nodes_ast       = Macro.escape(raw_nodes)
    connections_ast = Macro.escape(raw_connections)

    quote do
      @doc """
      Build and return the `%Phlox.Flow{}` for this module.
      Raises `ArgumentError` if the graph is invalid.
      """
      @spec flow() :: Phlox.Flow.t()
      def flow do
        alias Phlox.Graph

        builder =
          Enum.reduce(unquote(nodes_ast), Graph.new(), fn {id, mod, params, opts}, acc ->
            Graph.add_node(acc, id, mod, params, opts)
          end)

        builder =
          Enum.reduce(unquote(connections_ast), builder, fn {from, to, opts}, acc ->
            Graph.connect(acc, from, to, opts)
          end)

        builder
        |> Graph.start_at(unquote(start_id))
        |> Graph.to_flow!()
      end

      @doc """
      Run this flow with the given shared state (default `%{}`).
      Returns `{:ok, final_shared}` or `{:error, exception}`.
      """
      @spec run(map()) :: {:ok, map()} | {:error, Exception.t()}
      def run(shared \\ %{}) do
        Phlox.run(flow(), shared)
      end
    end
  end
end
