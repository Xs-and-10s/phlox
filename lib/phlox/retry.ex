defmodule Phlox.Retry do
  @moduledoc """
  Pure retry logic for node execution.

  Extracted from the orchestration loop so it can be tested in isolation
  and reasoned about independently of flow coordination.

  ## Semantics

  `max_retries` is the number of **retries after the first attempt**:

  - `max_retries: 0` — one attempt, no retries (the default)
  - `max_retries: 1` — two attempts total (one retry)
  - `max_retries: 3` — four attempts total (three retries)
  - `max_retries: :infinity` — retry forever until success (use with caution)

  Between retry attempts, `wait_ms` milliseconds are slept.
  If all attempts are exhausted, `exec_fallback/3` is called — which by
  default re-raises the last exception, but can be overridden per node.

  ## Interceptor support (V2.9)

  When an `exec_fn` is provided as the third argument, it replaces the
  direct `mod.exec(prep_res, params)` call. This allows interceptors to
  wrap each exec attempt inside the retry loop:

      interceptors = Phlox.Interceptor.read_interceptors(node.module)
      exec_fn = Phlox.Interceptor.wrap(node.module, node.id, node.params, interceptors)
      Phlox.Retry.run(node, prep_res, exec_fn)

  When `exec_fn` is `nil` (the default), `mod.exec(prep_res, params)` is
  called directly — fully backward compatible.
  """

  @type node_entry :: %{
          module: module(),
          params: map(),
          max_retries: non_neg_integer() | :infinity,
          wait_ms: non_neg_integer()
        }

  @doc """
  Run `node_entry.module.exec/2` with retry semantics.

  Returns the result of a successful `exec/2` call, or the result of
  `exec_fallback/3` if all retries are exhausted.

  ## Options

  - `exec_fn` — optional `(prep_res -> exec_res)` function. When provided,
    replaces the direct `mod.exec/2` call. Used by the interceptor system
    to wrap each exec attempt.
  """
  @spec run(node_entry(), term(), (term() -> term()) | nil) :: term()
  def run(node, prep_res, exec_fn \\ nil)

  def run(%{module: mod, params: params, max_retries: max, wait_ms: wait}, prep_res, exec_fn) do
    exec_fn = exec_fn || fn p -> mod.exec(p, params) end
    do_run(mod, prep_res, params, max, wait, 0, exec_fn)
  end

  # Single-clause retry loop. retry_count starts at 0 (the first attempt).
  # On failure, checks whether another retry is allowed.
  defp do_run(mod, prep_res, params, max, wait, retry_count, exec_fn) do
    try do
      exec_fn.(prep_res)
    rescue
      e ->
        if can_retry?(max, retry_count) do
          if wait > 0, do: Process.sleep(wait)
          do_run(mod, prep_res, params, max, wait, retry_count + 1, exec_fn)
        else
          mod.exec_fallback(prep_res, e, params)
        end
    end
  end

  defp can_retry?(:infinity, _retry_count), do: true
  defp can_retry?(max, retry_count), do: retry_count < max
end
