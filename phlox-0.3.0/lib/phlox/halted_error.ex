defmodule Phlox.HaltedError do
  @moduledoc """
  Raised when a `Phlox.Middleware` returns `{:halt, reason}`.

  ## Fields

  - `reason`     — the term returned in `{:halt, reason}`
  - `node_id`    — the node where the halt occurred
  - `middleware` — the middleware module that halted (if identifiable)
  - `phase`      — `:before_node` or `:after_node`
  """

  defexception [:reason, :node_id, :middleware, :phase]

  @impl Exception
  def message(%{reason: reason, node_id: node_id, phase: phase, middleware: mw}) do
    mw_str = if mw, do: " by #{inspect(mw)}", else: ""
    "Flow halted at :#{node_id} during #{phase}#{mw_str}: #{inspect(reason)}"
  end
end
