# sequential + parallel via Task.async_stream

defmodule Phlox.BatchNode do
  @moduledoc """
  A node variant whose `exec/2` receives a list and processes each item
  through `exec_one/2`, either sequentially or in parallel.

  ## Usage

      defmodule MyApp.FetchManyNode do
        use Phlox.BatchNode, parallel: true

        # prep/2 should return a list — same as Phlox.Node.prep/2
        @impl Phlox.Node
        def prep(shared, _params), do: Map.fetch!(shared, :urls)

        # exec_one/2 is called per item
        @impl Phlox.BatchNode
        def exec_one(url, _params) do
          HTTPoison.get!(url).body
        end

        # post/4 receives the full list of results — same as Phlox.Node.post/4
        @impl Phlox.Node
        def post(shared, _prep_res, results, _params) do
          {:default, Map.put(shared, :responses, results)}
        end
      end

  ## Options

  - `parallel: false` (default) — sequential `Enum.map`
  - `parallel: true`  — concurrent `Task.async_stream` with ordered results
  - `max_concurrency: pos_integer()` — only meaningful when `parallel: true`;
    defaults to `System.schedulers_online()`
  - `timeout: pos_integer()` — ms per task; defaults to 5000
  """

  # Only BatchNode-specific callbacks live here.
  # prep/2, exec/2, exec_fallback/3, and post/4 belong to Phlox.Node —
  # declaring them here too would cause duplicate-callback compiler warnings.
  @callback exec_one(item :: term(), params :: map()) :: term()
  @callback exec_fallback_one(item :: term(), exc :: Exception.t(), params :: map()) :: term()

  defmacro __using__(opts) do
    parallel = Keyword.get(opts, :parallel, false)
    max_concurrency = Keyword.get(opts, :max_concurrency, nil)
    timeout = Keyword.get(opts, :timeout, 5_000)

    quote do
      # Declare both behaviours. No callback conflicts because Phlox.BatchNode
      # only declares exec_one/2 and exec_fallback_one/3 as its own callbacks.
      @behaviour Phlox.BatchNode
      @behaviour Phlox.Node

      @phlox_batch_parallel unquote(parallel)
      @phlox_batch_max_concurrency unquote(max_concurrency)
      @phlox_batch_timeout unquote(timeout)

      @impl Phlox.Node
      def prep(_shared, _params), do: []

      @impl Phlox.BatchNode
      def exec_one(item, _params), do: item

      @impl Phlox.BatchNode
      def exec_fallback_one(_item, exc, _params), do: raise(exc)

      @impl Phlox.Node
      def exec_fallback(_prep_res, exc, _params), do: raise(exc)

      @impl Phlox.Node
      def post(shared, _prep_res, _results, _params), do: {:default, shared}

      # exec/2 is generated — maps exec_one over the list using the chosen strategy.
      # Users override exec_one/2, not exec/2 directly.
      @impl Phlox.Node
      def exec(items, params) when is_list(items) do
        if @phlox_batch_parallel do
          concurrency = @phlox_batch_max_concurrency || System.schedulers_online()
          timeout = @phlox_batch_timeout

          items
          |> Task.async_stream(
            fn item ->
              try do
                exec_one(item, params)
              rescue
                e -> exec_fallback_one(item, e, params)
              end
            end,
            max_concurrency: concurrency,
            timeout: timeout,
            ordered: true
          )
          |> Enum.map(fn {:ok, result} -> result end)
        else
          Enum.map(items, fn item ->
            try do
              exec_one(item, params)
            rescue
              e -> exec_fallback_one(item, e, params)
            end
          end)
        end
      end

      defoverridable prep: 2, exec_one: 2, exec_fallback_one: 3, post: 4
    end
  end
end
