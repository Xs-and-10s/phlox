# %Flow{} struct + run/2 → {:ok, shared} | {:error, e}

defmodule Phlox.Flow do
  @moduledoc """
  The `%Phlox.Flow{}` struct and its `run/2` entry point.

  Build a flow with `Phlox.Graph`, then run it:

      {:ok, flow} = Graph.new() |> Graph.add_node(...) |> ... |> Graph.to_flow()
      {:ok, final_shared} = Phlox.Flow.run(flow, %{initial: "state"})

  `run/2` delegates to `Phlox.Runner` and returns `{:ok, final_shared}`.
  Any unhandled exception from a node propagates as `{:error, exception}`.
  """

  alias Phlox.Runner

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
  """
  @spec run(t(), map()) :: {:ok, map()} | {:error, Exception.t()}
  def run(%__MODULE__{} = flow, shared \\ %{}) do
    try do
      final_shared = Runner.orchestrate(flow, flow.start_id, shared)
      {:ok, final_shared}
    rescue
      e -> {:error, e}
    end
  end
end
