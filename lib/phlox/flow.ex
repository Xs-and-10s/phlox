# %Flow{} struct + run/2 → {:ok, shared} | {:error, e}

defmodule Phlox.Flow do
  @moduledoc """
  The `%Phlox.Flow{}` struct and its `run/2` entry point.

  Build a flow with `Phlox.Graph`, then run it:

      {:ok, flow} = Graph.new() |> Graph.add_node(...) |> ... |> Graph.to_flow()
      {:ok, final_shared} = Phlox.Flow.run(flow, %{initial: "state"})

  `run/2` delegates to `Phlox.Pipeline` (with no middlewares), so
  telemetry events fire and `Phlox.Monitor` can track the execution.

  If `:phlox_flow_id` is not present in `shared`, a random ID is
  injected automatically. See `Phlox.Telemetry` for details.

  For a side-effect-free execution path (no telemetry), call
  `Phlox.Runner.orchestrate/3` directly.
  """

  alias Phlox.Pipeline

  @enforce_keys [:start_id, :nodes]
  defstruct [:start_id, nodes: %{}]

  @type t :: %__MODULE__{
          start_id: atom(),
          nodes: %{atom() => map()}
        }

  @doc """
  Run the flow with the given initial shared state.

  Returns `{:ok, final_shared}` on success, `{:error, exception}` if a node
  raises and all retries + fallbacks are exhausted.

  `final_shared` will contain a `:phlox_flow_id` key (user-supplied or
  auto-generated) used for telemetry correlation.
  """
  @spec run(t(), map()) :: {:ok, map()} | {:error, Exception.t()}
  def run(%__MODULE__{} = flow, shared \\ %{}) do
    try do
      final_shared = Pipeline.orchestrate(flow, flow.start_id, shared)
      {:ok, final_shared}
    rescue
      e -> {:error, e}
    end
  end
end
