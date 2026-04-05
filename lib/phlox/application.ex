defmodule Phlox.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for looking up FlowServer processes by user-supplied name.
      # Must start before FlowSupervisor so via-tuples resolve immediately.
      {Registry, keys: :unique, name: Phlox.FlowRegistry},

      # Real-time flow monitoring — ETS-backed, telemetry-attached.
      # Must start before FlowSupervisor so events from the first spawned
      # flow are captured.
      Phlox.Monitor,

      # DynamicSupervisor that spawns and supervises FlowServer processes.
      Phlox.FlowSupervisor
    ]

    opts = [strategy: :one_for_one, name: Phlox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
