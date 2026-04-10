defmodule Phlox.Retry do
  @moduledoc """
  Pure retry logic for node execution.

  Extracted from the orchestration loop so it can be tested in isolation
  and reasoned about independently of flow coordination.

  A node's `exec/2` is called up to `max_retries` times on exception.
  Between attempts, `wait_ms` milliseconds are slept.
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
          max_retries: non_neg_integer(),
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
    do_run(mod, prep_res, params, max, wait, 1, exec_fn)
  end

  defp do_run(mod, prep_res, params, max, _wait, attempt, exec_fn) when attempt >= max do
    try do
      exec_fn.(prep_res)
    rescue
      e -> mod.exec_fallback(prep_res, e, params)
    end
  end

  defp do_run(mod, prep_res, params, max, wait, attempt, exec_fn) do
    try do
      exec_fn.(prep_res)
    rescue
      _e ->
        if wait > 0, do: Process.sleep(wait)
        do_run(mod, prep_res, params, max, wait, attempt + 1, exec_fn)
    end
  end
end
