defmodule Phlox.Node do
  @moduledoc """
  Behaviour for Phlox graph nodes.

  Every node in a Phlox flow is a module that implements this behaviour.
  The three-phase lifecycle — `prep → exec → post` — keeps data reading
  (prep), computation (exec), and state writing (post) cleanly separated.
  The defaults are safe no-ops.

  ## Usage

      defmodule MyApp.FetchNode do
        use Phlox.Node

        def prep(shared, _params), do: Map.fetch!(shared, :url)

        def exec(url, _params) do
          HTTPoison.get!(url).body
        end

        def post(shared, _prep, body, _params) do
          {:default, Map.put(shared, :body, body)}
        end
      end

  ## Interceptors (V2.9)

  Nodes can declare interceptors that wrap `exec/2` at the
  computation boundary:

      defmodule MyApp.EmbedNode do
        use Phlox.Node

        intercept MyApp.Interceptor.Cache, ttl: :timer.minutes(5)
        intercept MyApp.Interceptor.RateLimit, max: 10, per: :second

        def exec(text, _params), do: MyLLM.embed(text)
      end

  See `Phlox.Interceptor` for the interceptor behaviour and semantics.
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

      # Interceptor support (V2.9)
      import Phlox.Interceptor, only: [intercept: 1, intercept: 2]
      Module.register_attribute(__MODULE__, :phlox_interceptors, accumulate: true)
      @before_compile Phlox.Interceptor

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
