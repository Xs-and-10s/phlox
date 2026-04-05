# exec_with_retry, extracted and independently

defmodule Phlox.Retry do
  @moduledoc """
  Pure retry logic for node execution.

  Extracted from the orchestration loop so it can be tested in isolation
  and reasoned about independently of flow coordination.

  A node's `exec/2` is called up to `max_retries` times on exception.
  Between attempts, `wait_ms` milliseconds are slept.
  If all attempts are exhausted, `exec_fallback/3` is called — which by
  default re-raises the last exception, but can be overridden per node.
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
  """
  @spec run(node_entry(), term()) :: term()
  def run(%{module: mod, params: params, max_retries: max, wait_ms: wait}, prep_res) do
    do_run(mod, prep_res, params, max, wait, 1)
  end

  defp do_run(mod, prep_res, params, max, _wait, attempt) when attempt >= max do
    try do
      mod.exec(prep_res, params)
    rescue
      e -> mod.exec_fallback(prep_res, e, params)
    end
  end

  defp do_run(mod, prep_res, params, max, wait, attempt) do
    try do
      mod.exec(prep_res, params)
    rescue
      _e ->
        if wait > 0, do: Process.sleep(wait)
        do_run(mod, prep_res, params, max, wait, attempt + 1)
    end
  end
end
