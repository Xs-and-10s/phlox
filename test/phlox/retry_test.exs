defmodule Phlox.RetryTest do
  use ExUnit.Case, async: true

  # --- test node modules defined inline ---

  defmodule AlwaysSucceeds do
    use Phlox.Node
    def exec(prep_res, _params), do: {:ok, prep_res}
  end

  defmodule FailsThenSucceeds do
    use Phlox.Node
    # Uses the process dictionary as a call counter — acceptable in tests
    def exec(input, _params) do
      count = Process.get(:attempt_count, 0)
      Process.put(:attempt_count, count + 1)
      if count < 2, do: raise("not yet"), else: {:ok, input}
    end
  end

  defmodule AlwaysFails do
    use Phlox.Node
    def exec(_prep_res, _params), do: raise("always fails")
    def exec_fallback(_prep_res, exc, _params), do: {:fallback, Exception.message(exc)}
  end

  defmodule AlwaysFailsReraises do
    use Phlox.Node
    def exec(_prep_res, _params), do: raise(RuntimeError, "boom")
  end

  # --- helpers ---

  defp node_entry(mod, opts \\ []) do
    %{
      module: mod,
      params: Keyword.get(opts, :params, %{}),
      max_retries: Keyword.get(opts, :max_retries, 1),
      wait_ms: Keyword.get(opts, :wait_ms, 0)
    }
  end

  # --- tests ---

  test "returns result directly when exec succeeds on first attempt" do
    assert Phlox.Retry.run(node_entry(AlwaysSucceeds), "hello") == {:ok, "hello"}
  end

  test "retries and succeeds after initial failures" do
    Process.put(:attempt_count, 0)
    result = Phlox.Retry.run(node_entry(FailsThenSucceeds, max_retries: 3), "data")
    assert result == {:ok, "data"}
    assert Process.get(:attempt_count) == 3
  end

  test "calls exec_fallback when all retries exhausted" do
    result = Phlox.Retry.run(node_entry(AlwaysFails, max_retries: 2), "input")
    assert result == {:fallback, "always fails"}
  end

  test "default exec_fallback re-raises the exception" do
    assert_raise RuntimeError, "boom", fn ->
      Phlox.Retry.run(node_entry(AlwaysFailsReraises, max_retries: 1), "input")
    end
  end

  test "max_retries: 1 means exactly one attempt with no retry" do
    Process.put(:attempt_count, 0)
    # FailsThenSucceeds needs 3 attempts; with max 1 it should fall through to fallback
    assert_raise RuntimeError, "not yet", fn ->
      Phlox.Retry.run(node_entry(FailsThenSucceeds, max_retries: 1), "data")
    end
  end
end
