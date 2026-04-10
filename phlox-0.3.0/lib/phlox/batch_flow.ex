# sequential + parallel multi-run, param-override injection

defmodule Phlox.BatchFlow do
  @moduledoc """
  A flow variant that runs an inner `Phlox.Flow` multiple times, once per
  entry in a list of param-override maps returned by `prep/1`.

  ## Contract

  Implement `prep/1` to return a list of param maps. Each map is deep-merged
  into the inner flow's node params for that run. The runs share the same
  initial `shared` map but each run's mutations are independent — shared state
  does not bleed between runs.

  ## Usage

      defmodule MyApp.BulkFetchBatch do
        use Phlox.BatchFlow, parallel: false

        @impl Phlox.BatchFlow
        def prep(shared) do
          Enum.map(shared.urls, fn url -> %{url: url} end)
        end
      end

      {:ok, results} =
        MyApp.BulkFetchBatch.run(inner_flow, %{urls: ["https://a.com", "https://b.com"]})

  ## Options

  - `parallel: false` (default) — runs are sequential; `shared` from run N
    is passed as the base for run N+1. Useful for pipelines where runs depend
    on previous results.
  - `parallel: true` — runs are concurrent via `Task.async_stream`; all runs
    receive the same initial `shared`, and results are collected as a list of
    final shared maps. Mutations do not propagate between runs.
  - `max_concurrency:` and `timeout:` — same semantics as `Phlox.BatchNode`.
  """

  alias Phlox.{Flow, Runner}

  @callback prep(shared :: map()) :: [map()]

  defmacro __using__(opts) do
    parallel = Keyword.get(opts, :parallel, false)
    max_concurrency = Keyword.get(opts, :max_concurrency, nil)
    timeout = Keyword.get(opts, :timeout, 5_000)

    quote do
      @behaviour Phlox.BatchFlow

      @phlox_parallel unquote(parallel)
      @phlox_max_concurrency unquote(max_concurrency)
      @phlox_timeout unquote(timeout)

      @impl Phlox.BatchFlow
      def prep(_shared), do: []

      defoverridable prep: 1

      @doc """
      Run the inner flow once per entry returned by `prep/1`.
      Returns `{:ok, final_shared_or_results}`.
      """
      @spec run(Flow.t(), map()) :: {:ok, map() | [map()]} | {:error, Exception.t()}
      def run(%Flow{} = inner_flow, shared \\ %{}) do
        param_sets = prep(shared)

        try do
          result =
            if @phlox_parallel do
              concurrency = @phlox_max_concurrency || System.schedulers_online()
              timeout = @phlox_timeout

              param_sets
              |> Task.async_stream(
                fn param_override ->
                  patched_flow = apply_param_override(inner_flow, param_override)
                  Runner.orchestrate(patched_flow, patched_flow.start_id, shared)
                end,
                max_concurrency: concurrency,
                timeout: timeout,
                ordered: true
              )
              |> Enum.map(fn {:ok, final_shared} -> final_shared end)
            else
              Enum.reduce(param_sets, shared, fn param_override, current_shared ->
                patched_flow = apply_param_override(inner_flow, param_override)
                Runner.orchestrate(patched_flow, patched_flow.start_id, current_shared)
              end)
            end

          {:ok, result}
        rescue
          e -> {:error, e}
        end
      end

      # Deep-merges param_override into every node's params in the flow.
      # This lets a BatchFlow supply per-run config without knowing node internals.
      defp apply_param_override(%Flow{nodes: nodes} = flow, override) when map_size(override) == 0,
        do: flow

      defp apply_param_override(%Flow{nodes: nodes} = flow, override) do
        patched =
          Map.new(nodes, fn {id, node} ->
            {id, %{node | params: Map.merge(node.params, override)}}
          end)

        %Flow{flow | nodes: patched}
      end
    end
  end
end
