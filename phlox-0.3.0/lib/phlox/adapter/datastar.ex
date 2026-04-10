defmodule Phlox.Adapter.Datastar do
  @moduledoc ~S"""
  Datastar SSE integration for `Phlox.Monitor`.

  Streams real-time flow state to any Datastar-enabled frontend via
  Server-Sent Events, using the `datastar_ex` Elixir SDK. Works with
  any Plug-compatible server: Bandit, Cowboy, or Phoenix — no LiveView
  required.

  ## Dependencies

  Add to your `mix.exs`:

      {:datastar, "~> 0.1"},   # the datastar_ex SDK (owned by you)
      {:jason,    "~> 1.4"}    # required by the Datastar SDK

  ## How it works

      Phlox.Monitor                Datastar.SSE loop
      ────────────                 ─────────────────
      {:phlox_monitor, :node_done, snapshot}
              │
              ▼
      Datastar.Signals.patch(sse, %{phlox_status: "running", ...})
      Datastar.Elements.patch(sse, node_html, selector: "#phlox-nodes", mode: :inner)

  ## Setup

  ### With Phoenix Router

      # router.ex
      get "/phlox/stream/:flow_id", Phlox.Adapter.Datastar.Plug, []

  ### With Bandit/Plug.Router

      forward "/phlox/stream", to: Phlox.Adapter.Datastar.Plug

  ### Minimal frontend

      <div data-signals='{"phlox_status":"ready","phlox_current_node":""}'>
        <%!-- Open SSE stream on page load --%>
        <div data-on-load="@get('/phlox/stream/my-flow-id')"></div>

        <span data-text="$phlox_status"></span>

        <div id="phlox-nodes">
          <%!-- Phlox patches node rows in here as they execute --%>
        </div>
      </div>

  ## Signals emitted

  | Signal | Value |
  |---|---|
  | `$phlox_status` | `"ready"` \| `"running"` \| `"done"` \| `"error"` |
  | `$phlox_current_node` | atom string of the running node, or `""` |
  | `$phlox_started_at` | ISO8601 string, or `""` |
  | `$phlox_node_{id}_status` | per-node: `"pending"` \| `"running"` \| `"done"` \| `"error"` |
  | `$phlox_node_{id}_duration_ms` | per-node integer ms, or `null` |

  ## Availability

  This module compiles on all Elixir installations. `Phlox.Adapter.Datastar.Plug`
  and `stream/2` are only usable when the `datastar` SDK and `plug` are loaded.
  """

  @datastar_available Code.ensure_loaded?(Datastar.SSE)
  @plug_available     Code.ensure_loaded?(Plug.Conn)

  # ---------------------------------------------------------------------------
  # stream/2 — the core SSE loop; call from any Plug handler
  # ---------------------------------------------------------------------------

  @doc """
  Open a Datastar SSE stream for `flow_id` on `conn`.

  Subscribes to `Phlox.Monitor`, sends the current snapshot immediately,
  then sends patches as monitor events arrive. Returns the conn after
  the stream closes (client disconnect or flow terminal event).
  """
  def stream(conn, flow_id) do
    unless @datastar_available and @plug_available do
      raise """
      Phlox.Adapter.Datastar.stream/2 requires the datastar_ex SDK and plug.
      Add {:datastar, "~> 0.1"} and {:plug, "~> 1.0"} to your mix.exs deps.
      """
    end

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
      |> Plug.Conn.send_chunked(200)

    sse = Datastar.SSE.new(conn)

    Phlox.Monitor.subscribe(flow_id)

    sse =
      case Phlox.Monitor.get(flow_id) do
        nil ->
          Datastar.Signals.patch(sse, %{
            "phlox_status"       => "waiting",
            "phlox_current_node" => ""
          })

        snapshot ->
          sse
          |> patch_signals(snapshot)
          |> patch_nodes(snapshot)
      end

    final_sse = sse_loop(sse, flow_id)
    final_sse.conn
  end

  # ---------------------------------------------------------------------------
  # Private — SSE receive loop
  # ---------------------------------------------------------------------------

  defp sse_loop(sse, flow_id) do
    receive do
      {:phlox_monitor, event, snapshot} ->
        try do
          sse =
            sse
            |> patch_signals(snapshot)
            |> patch_nodes(snapshot)

          if terminal_event?(event), do: sse, else: sse_loop(sse, flow_id)
        rescue
          # Datastar.SSE.send_event! raises when the client disconnects
          _ -> sse
        end

    after
      # Keepalive — prevents proxy/browser SSE timeout
      15_000 ->
        try do
          sse = Datastar.Signals.patch(sse, %{"phlox_keepalive" => System.system_time(:second)})
          sse_loop(sse, flow_id)
        rescue
          _ -> sse
        end
    end
  end

  defp terminal_event?(:flow_done),  do: true
  defp terminal_event?(:flow_error), do: true
  defp terminal_event?(_),           do: false

  # ---------------------------------------------------------------------------
  # Private — signal / element patching
  # ---------------------------------------------------------------------------

  defp patch_signals(sse, snapshot) do
    node_signals =
      Enum.reduce(snapshot.nodes, %{}, fn {node_id, node}, acc ->
        prefix = "phlox_node_#{node_id}"

        acc
        |> Map.put("#{prefix}_status",      node_status_string(node.status))
        |> Map.put("#{prefix}_duration_ms", node.duration_ms)
      end)

    signals =
      Map.merge(node_signals, %{
        "phlox_status"       => status_string(snapshot.status),
        "phlox_current_node" => to_string(snapshot.current_id || ""),
        "phlox_started_at"   => datetime_string(snapshot[:started_at])
      })

    Datastar.Signals.patch(sse, signals)
  end

  defp patch_nodes(sse, %{nodes: nodes}) when map_size(nodes) == 0, do: sse

  defp patch_nodes(sse, snapshot) do
    html = render_nodes_html(snapshot.nodes)

    Datastar.Elements.patch(sse, html, selector: "#phlox-nodes", mode: :inner)
  end

  defp render_nodes_html(nodes) do
    rows =
      Enum.map_join(nodes, "\n", fn {node_id, node} ->
        css_class = "phlox-node phlox-node-#{node_status_string(node.status)}"
        duration  = if node.duration_ms, do: "#{node.duration_ms}ms", else: "—"

        ~s(<tr id="phlox-node-#{node_id}" class="#{css_class}">) <>
          ~s(<td class="phlox-node-id">#{node_id}</td>) <>
          ~s(<td class="phlox-node-status">#{node_status_string(node.status)}</td>) <>
          ~s(<td class="phlox-node-duration">#{duration}</td>) <>
          ~s(</tr>)
      end)

    ~s(<table class="phlox-nodes">#{rows}</table>)
  end

  # ---------------------------------------------------------------------------
  # Private — value formatting
  # ---------------------------------------------------------------------------

  defp status_string(:ready),       do: "ready"
  defp status_string(:running),     do: "running"
  defp status_string(:done),        do: "done"
  defp status_string({:error, _}),  do: "error"
  defp status_string(_),            do: "unknown"

  defp node_status_string(:running),     do: "running"
  defp node_status_string(:done),        do: "done"
  defp node_status_string({:error, _}),  do: "error"
  defp node_status_string(_),            do: "pending"

  defp datetime_string(nil),              do: ""
  defp datetime_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
