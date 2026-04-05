if Code.ensure_loaded?(Plug.Conn) do
  defmodule Phlox.Adapter.Datastar.Plug do
    @moduledoc """
    A Plug that opens a Datastar SSE stream for a named flow.

    Reads `flow_id` from path params, then falls back to query params,
    then the last path segment.

    ## With Phoenix Router

        get "/phlox/stream/:flow_id", Phlox.Adapter.Datastar.Plug, []

    ## With Plug.Router

        forward "/phlox/stream", to: Phlox.Adapter.Datastar.Plug
    """

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      flow_id =
        conn.path_params["flow_id"] ||
          conn.params["flow_id"] ||
          List.last(conn.path_info)

      Phlox.Adapter.Datastar.stream(conn, flow_id)
    end
  end
end
