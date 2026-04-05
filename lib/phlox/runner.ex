# pure orchestration loop, OTP-free by design

defmodule Phlox.Runner do
  @moduledoc """
  Pure orchestration loop for `Phlox.Flow`.

  This module is intentionally OTP-free. It is a set of plain functions
  that thread `shared` state through a graph of nodes. Because it has no
  process coupling, it can be:

  - called directly from tests
  - wrapped in a `GenServer` (Phlox.FlowServer, coming in V2) with zero changes
  - composed into larger orchestration systems

  ## The loop

      orchestrate(flow, current_id, shared)
        node  = flow.nodes[current_id]
        prep  = node.module.prep(shared, merged_params)
        exec  = Phlox.Retry.run(node, prep)
        {action, new_shared} = node.module.post(shared, prep, exec, merged_params)
        next  = resolve_next(node, action)
        recurse with (next, new_shared)   -- or return new_shared if no next node

  `shared` is never mutated; each call receives and returns a plain map.
  """

  alias Phlox.{Flow, Retry}

  @doc """
  Orchestrate a flow starting from `start_id` with the given shared state.

  Returns the final `shared` map after the last node in the path runs.
  Raises if a node raises and all retries/fallbacks are exhausted.
  """
  @spec orchestrate(Flow.t(), atom(), map()) :: map()
  def orchestrate(%Flow{} = flow, start_id, shared) do
    node = fetch_node!(flow, start_id)
    step(flow, node, shared)
  end

  # --- private ---

  defp step(flow, node, shared) do
    params = node.params

    prep_res = node.module.prep(shared, params)
    exec_res = Retry.run(node, prep_res)
    {action, new_shared} = node.module.post(shared, prep_res, exec_res, params)

    case resolve_next(flow, node, action) do
      nil -> new_shared
      next_node -> step(flow, next_node, new_shared)
    end
  end

  defp resolve_next(flow, node, action) do
    # Normalise :default atom to the string "default"
    action_key =
      case action do
        :default -> "default"
        str when is_binary(str) -> str
      end

    case Map.get(node.successors, action_key) do
      nil ->
        if map_size(node.successors) > 0 do
          IO.warn(
            "Phlox.Runner: flow ends — action '#{action_key}' not found in #{inspect(Map.keys(node.successors))} for node :#{node.id}",
            []
          )
        end

        nil

      next_id ->
        fetch_node!(flow, next_id)
    end
  end

  defp fetch_node!(%Flow{nodes: nodes}, id) do
    case Map.fetch(nodes, id) do
      {:ok, node} ->
        node

      :error ->
        raise ArgumentError,
              "Phlox.Runner: node :#{id} referenced but not found in graph. " <>
                "Known nodes: #{inspect(Map.keys(nodes))}"
    end
  end
end
