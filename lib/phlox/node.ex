# @behaviour + __using__ with all four callbacks

defmodule Phlox.Node do
  @moduledoc """
  The core behaviour for all Phlox nodes.

  ## Lifecycle

  Every node runs three phases in sequence:

      prep(shared, params)
        -> exec(prep_res, params)
          -> post(shared, prep_res, exec_res, params)
            -> {action, new_shared}

  - `prep/2`   — reads from `shared`; returns data needed by `exec`. Pure — no side effects.
  - `exec/2`   — does the actual work (HTTP calls, LLM requests, DB writes). Receives only
                  `prep_res` and `params` — no access to `shared`. This is intentional:
                  exec should be a pure transformation or I/O call, not a state manager.
  - `post/4`   — decides what happens next. Returns `{action_string, updated_shared}`.
                  The action string is used to look up the next node in the graph.
                  Use `:default` or `"default"` for the normal forward path.
  - `exec_fallback/3` — called when all `max_retries` are exhausted. Default re-raises.

  ## Usage

      defmodule MyApp.FetchNode do
        use Phlox.Node

        @impl Phlox.Node
        def exec(url, _params) do
          # do HTTP stuff
          {:ok, body}
        end

        @impl Phlox.Node
        def post(shared, _prep_res, {:ok, body}, _params) do
          {:default, Map.put(shared, :body, body)}
        end

        def post(shared, _prep_res, {:error, reason}, _params) do
          {"error", Map.put(shared, :error, reason)}
        end
      end

  Only override what you need. The defaults are safe no-ops.
  """

  @doc """
  Reads from shared state and produces input for `exec/2`.
  Return value is passed as `prep_res` to both `exec/2` and `post/4`.
  Default: returns `nil`.
  """
  @callback prep(shared :: map(), params :: map()) :: term()

  @doc """
  Performs the node's primary work. Has no access to `shared` — this keeps
  exec pure and independently testable. May raise; retry logic wraps it.
  Default: returns `prep_res` unchanged (passthrough).
  """
  @callback exec(prep_res :: term(), params :: map()) :: term()

  @doc """
  Called when all retries are exhausted. Receives the last exception.
  Default: re-raises the exception.
  """
  @callback exec_fallback(prep_res :: term(), exc :: Exception.t(), params :: map()) :: term()

  @doc """
  Decides the next action and updates shared state.
  Must return `{action, new_shared}` where action is a string or `:default`.
  Default: returns `{:default, shared}` unchanged.
  """
  @callback post(
              shared :: map(),
              prep_res :: term(),
              exec_res :: term(),
              params :: map()
            ) :: {action :: String.t() | :default, new_shared :: map()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Phlox.Node

      @impl Phlox.Node
      def prep(_shared, _params), do: nil

      @impl Phlox.Node
      def exec(prep_res, _params), do: prep_res

      @impl Phlox.Node
      def exec_fallback(_prep_res, exc, _params), do: raise(exc)

      @impl Phlox.Node
      def post(shared, _prep_res, _exec_res, _params), do: {:default, shared}

      defoverridable prep: 2, exec: 2, exec_fallback: 3, post: 4
    end
  end
end
