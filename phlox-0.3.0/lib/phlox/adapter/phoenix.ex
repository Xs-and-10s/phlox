defmodule Phlox.Adapter.Phoenix do
  @moduledoc """
  Phoenix LiveView integration for `Phlox.Monitor`.

  Brings real-time flow monitoring into any LiveView with a single `use` line.
  Requires `phoenix_live_view` in your deps; compiles everywhere but raises a
  clear error if used without it.

  ## Option A — `use` mixin in your own LiveView

      defmodule MyAppWeb.IngestLive do
        use MyAppWeb, :live_view
        use Phlox.Adapter.Phoenix

        def mount(%{"flow_id" => flow_id}, _session, socket) do
          {:ok, phlox_subscribe(socket, flow_id)}
        end

        # @phlox_status, @phlox_current_node, @phlox_nodes, @phlox_started_at
        # are all available as assigns after phlox_subscribe/2.
        def render(assigns), do: ...

        # Optional hook — override to respond to specific events
        def handle_phlox_event(:flow_done, _snap, socket) do
          {:noreply, put_flash(socket, :info, "Done!")}
        end
      end

  ## Option B — drop-in LiveComponent

      <.live_component
        module={Phlox.Adapter.Phoenix.FlowMonitor}
        id="my-monitor"
        flow_id={@flow_id}
      />

  ## Assigns injected by `phlox_subscribe/2`

  - `@phlox_flow_id`      — the subscribed flow ID
  - `@phlox_status`       — `:ready | :running | :done | {:error, exc}`
  - `@phlox_current_node` — atom ID of the running node, or `nil`
  - `@phlox_nodes`        — `%{node_id => %{status, duration_ms, ...}}`
  - `@phlox_started_at`   — `DateTime` or `nil`
  """

  @live_view_available Code.ensure_loaded?(Phoenix.LiveView)

  # ---------------------------------------------------------------------------
  # `use Phlox.Adapter.Phoenix` — injects handle_info/2 and phlox_subscribe/2
  # ---------------------------------------------------------------------------

  defmacro __using__(_opts) do
    # Evaluated in the definer's (Phlox.Adapter.Phoenix) compile context,
    # not the caller's — so Code.ensure_loaded? is safe here.
    live_view_available = Code.ensure_loaded?(Phoenix.LiveView)

    if live_view_available do
      quote do
        import Phlox.Adapter.Phoenix, only: [phlox_subscribe: 2]

        @doc false
        def handle_info({:phlox_monitor, event, snapshot}, socket) do
          socket = Phlox.Adapter.Phoenix.__apply_snapshot__(socket, snapshot)

          if function_exported?(__MODULE__, :handle_phlox_event, 3) do
            apply(__MODULE__, :handle_phlox_event, [event, snapshot, socket])
          else
            {:noreply, socket}
          end
        end
      end
    else
      quote do
        @doc false
        def __phlox_phoenix_unavailable__ do
          raise """
          Phlox.Adapter.Phoenix requires phoenix_live_view.
          Add {:phoenix_live_view, "~> 1.0"} to your mix.exs deps.
          """
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  @doc """
  Subscribe to `Phlox.Monitor` for `flow_id` and initialise monitoring assigns.
  Call from `mount/3`. Returns the socket with all `@phlox_*` assigns set.
  """
  def phlox_subscribe(socket, flow_id) do
    if live_view_connected?(socket) do
      Phlox.Monitor.subscribe(flow_id)
    end

    socket
    |> set_phlox_defaults(flow_id)
    |> apply_existing_snapshot(flow_id)
  end

  @doc false
  def __apply_snapshot__(socket, snapshot) do
    phoenix_assign(socket,
      phlox_status:       snapshot.status,
      phlox_current_node: snapshot.current_id,
      phlox_nodes:        snapshot.nodes,
      phlox_started_at:   snapshot[:started_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp set_phlox_defaults(socket, flow_id) do
    phoenix_assign(socket,
      phlox_flow_id:      flow_id,
      phlox_status:       :ready,
      phlox_current_node: nil,
      phlox_nodes:        %{},
      phlox_started_at:   nil
    )
  end

  defp apply_existing_snapshot(socket, flow_id) do
    case Phlox.Monitor.get(flow_id) do
      nil      -> socket
      snapshot -> __apply_snapshot__(socket, snapshot)
    end
  end

  defp live_view_connected?(socket) do
    if @live_view_available do
      Phoenix.LiveView.connected?(socket)
    else
      false
    end
  end

  defp phoenix_assign(socket, assigns) do
    if @live_view_available do
      Phoenix.Component.assign(socket, assigns)
    else
      socket
    end
  end
end
