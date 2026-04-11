defmodule Phlox.Property.RetryContractTest do
  @moduledoc """
  Property-based test for Phlox.Retry call-count contract.

  `max_retries` is the number of retries *after* the first attempt:

  - max_retries: 0 → 1 total attempt (first try only)
  - max_retries: N → N+1 total attempts (first try + N retries)
  - max_retries: :infinity → retries forever until success

  For a function that fails K times then succeeds:
  - If K <= max_retries, exec is called K+1 times (K failures + 1 success)
  - If K > max_retries, exec is called max_retries+1 times and exec_fallback fires
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Phlox.Retry

  # ---------------------------------------------------------------------------
  # Test node module with non-raising exec_fallback
  # ---------------------------------------------------------------------------

  defmodule CounterNode do
    use Phlox.Node
    def exec_fallback(_prep, exc, _params), do: {:fallback, exc}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp node_entry(max_retries) do
    %{
      module: CounterNode,
      params: %{},
      max_retries: max_retries,
      wait_ms: 0
    }
  end

  defp counting_exec_fn(fail_count, agent) do
    fn _prep_res ->
      count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

      if count < fail_count do
        raise RuntimeError, "attempt #{count + 1} failed"
      else
        {:success, count + 1}
      end
    end
  end

  defp start_counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp get_count(agent), do: Agent.get(agent, & &1)

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "succeeds after K failures when max_retries >= K" do
    check all max_retries <- integer(0..15),
              fail_count <- integer(0..max_retries),
              max_runs: 300 do
      agent = start_counter()
      exec_fn = counting_exec_fn(fail_count, agent)

      result = Retry.run(node_entry(max_retries), :prep_data, exec_fn)

      assert {:success, _} = result

      # Total calls = fail_count failures + 1 success
      expected_calls = fail_count + 1
      assert get_count(agent) == expected_calls,
        "Expected #{expected_calls} calls, got #{get_count(agent)} " <>
        "(max_retries: #{max_retries}, fail_count: #{fail_count})"

      Agent.stop(agent)
    end
  end

  property "calls exec_fallback when failures exceed max_retries" do
    check all max_retries <- integer(0..10),
              extra <- integer(1..5),
              max_runs: 200 do
      fail_count = max_retries + extra
      agent = start_counter()
      exec_fn = counting_exec_fn(fail_count, agent)

      result = Retry.run(node_entry(max_retries), :prep_data, exec_fn)

      assert {:fallback, %RuntimeError{}} = result

      # Total calls = first attempt + max_retries retries
      expected_calls = 1 + max_retries
      assert get_count(agent) == expected_calls,
        "Expected #{expected_calls} calls, got #{get_count(agent)} " <>
        "(max_retries: #{max_retries}, fail_count: #{fail_count})"

      Agent.stop(agent)
    end
  end

  property "max_retries: 0 means exactly one attempt, no retry" do
    check all fail <- boolean(), max_runs: 100 do
      agent = start_counter()
      fail_count = if fail, do: 1, else: 0
      exec_fn = counting_exec_fn(fail_count, agent)

      result = Retry.run(node_entry(0), :prep_data, exec_fn)

      assert get_count(agent) == 1

      if fail do
        assert {:fallback, %RuntimeError{}} = result
      else
        assert {:success, 1} = result
      end

      Agent.stop(agent)
    end
  end

  property "succeeds on first try regardless of max_retries" do
    check all max_retries <- integer(0..20), max_runs: 100 do
      agent = start_counter()
      exec_fn = counting_exec_fn(0, agent)

      result = Retry.run(node_entry(max_retries), :prep_data, exec_fn)

      assert {:success, 1} = result
      assert get_count(agent) == 1

      Agent.stop(agent)
    end
  end

  property "wait_ms doesn't affect the outcome" do
    check all max_retries <- integer(1..5),
              fail_count <- integer(0..5),
              fail_count <= max_retries,
              wait_ms <- member_of([0, 1]),
              max_runs: 100 do
      agent = start_counter()
      node = %{node_entry(max_retries) | wait_ms: wait_ms}
      exec_fn = counting_exec_fn(fail_count, agent)

      result = Retry.run(node, :prep_data, exec_fn)

      assert {:success, _} = result
      assert get_count(agent) == fail_count + 1

      Agent.stop(agent)
    end
  end

  property "prep_res is forwarded to every exec attempt unchanged" do
    check all max_retries <- integer(1..5),
              prep_data <- binary(min_length: 1),
              max_runs: 100 do
      received = Agent.start_link(fn -> [] end) |> elem(1)

      exec_fn = fn prep_res ->
        Agent.update(received, fn list -> [prep_res | list] end)
        :ok
      end

      Retry.run(node_entry(max_retries), prep_data, exec_fn)

      values = Agent.get(received, & &1)
      assert Enum.all?(values, &(&1 == prep_data))

      Agent.stop(received)
    end
  end

  property "negative max_retries raises at Graph.add_node time" do
    check all n <- integer(-100..-1), max_runs: 50 do
      assert_raise ArgumentError, ~r/max_retries/, fn ->
        Phlox.Graph.new()
        |> Phlox.Graph.add_node(:a, CounterNode, %{}, max_retries: n)
      end
    end
  end
end
