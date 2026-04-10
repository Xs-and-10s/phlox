if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Phlox.Adapter.Phoenix.FlowMonitor do
    @moduledoc """
    A self-contained LiveComponent that renders a real-time flow monitor.

    Drop into any LiveView template:

        <.live_component
          module={Phlox.Adapter.Phoenix.FlowMonitor}
          id={"monitor-\#{@flow_id}"}
          flow_id={@flow_id}
        />

    Subscribes to `Phlox.Monitor` on mount and re-renders automatically
    as nodes execute. Renders a minimal status table by default.

    ## Customising the render

    Pass a `:render_fn` assign (1-arity function receiving assigns)
    for inline customisation:

        <.live_component
          module={Phlox.Adapter.Phoenix.FlowMonitor}
          id="my-monitor"
          flow_id={@flow_id}
          render_fn={fn assigns ->
            ~H\"""
            <span>{assigns.phlox_status}</span>
            \"""
          end}
        />
    """

    use Phoenix.LiveComponent

    alias Phlox.Adapter.Phoenix, as: PhloxPhoenix

    @impl Phoenix.LiveComponent
    def mount(socket) do
      {:ok, assign(socket, render_fn: nil)}
    end

    @impl Phoenix.LiveComponent
    def update(%{flow_id: flow_id} = assigns, socket) do
      socket =
        socket
        |> assign(assigns)
        |> PhloxPhoenix.phlox_subscribe(flow_id)

      {:ok, socket}
    end

    @impl Phoenix.LiveComponent
    def handle_info({:phlox_monitor, _event, snapshot}, socket) do
      {:noreply, PhloxPhoenix.__apply_snapshot__(socket, snapshot)}
    end

    @impl Phoenix.LiveComponent
    def render(%{render_fn: fun} = assigns) when is_function(fun, 1), do: fun.(assigns)

    def render(assigns) do
      ~H"""
      <div class="phlox-monitor" id={@id}>
        <div class="phlox-monitor-header">
          <span class={"phlox-status phlox-status-#{status_class(@phlox_status)}"}>
            <%= status_label(@phlox_status) %>
          </span>
          <%= if @phlox_current_node do %>
            <span class="phlox-current-node">→ <%= @phlox_current_node %></span>
          <% end %>
        </div>
        <table class="phlox-nodes">
          <%= for {node_id, node} <- @phlox_nodes do %>
            <tr class={"phlox-node phlox-node-#{node_class(node.status)}"}>
              <td><%= node_id %></td>
              <td><%= node_label(node.status) %></td>
              <td><%= if node.duration_ms, do: "#{node.duration_ms}ms", else: "—" %></td>
            </tr>
          <% end %>
        </table>
      </div>
      """
    end

    defp status_label(:ready),       do: "Ready"
    defp status_label(:running),     do: "Running"
    defp status_label(:done),        do: "Done"
    defp status_label({:error, _}),  do: "Error"

    defp status_class(:ready),       do: "ready"
    defp status_class(:running),     do: "running"
    defp status_class(:done),        do: "done"
    defp status_class({:error, _}),  do: "error"

    defp node_label(:running),       do: "▶"
    defp node_label(:done),          do: "✓"
    defp node_label({:error, _}),    do: "✗"
    defp node_label(_),              do: "·"

    defp node_class(:running),       do: "running"
    defp node_class(:done),          do: "done"
    defp node_class({:error, _}),    do: "error"
    defp node_class(_),              do: "pending"
  end
end
