defmodule Phlox.Interceptor do
  @moduledoc """
  A node-declared hook around the `exec/2` boundary.

  Interceptors are the complement to Middleware. Where middleware wraps
  the entire node lifecycle (before prep, after post) and is configured
  at the *pipeline* level, interceptors wrap *just exec* and are declared
  by the *node itself*.

  **Middleware** = what the framework does to every node.
  **Interceptors** = what nodes declare they want done to themselves.

  ## The exec boundary

  Interceptors run inside the retry loop, wrapping each attempt:

      Retry loop:
        attempt 1 → before_exec → exec → after_exec → (raises)
        attempt 2 → before_exec → exec → after_exec → (raises)
        attempt 3 → before_exec → exec → after_exec → success

  ## Declaring interceptors on a node

      defmodule MyApp.EmbedNode do
        use Phlox.Node

        intercept Phlox.Interceptor.Cache, ttl: :timer.minutes(5)
        intercept Phlox.Interceptor.RateLimit, max: 10, per: :second

        def exec(text, _params), do: MyLLM.embed(text)
      end

  Interceptors execute in declaration order for `before_exec`, and
  reverse declaration order for `after_exec` (onion model, same as
  middleware).

  ## Implementing an interceptor

      defmodule Phlox.Interceptor.Cache do
        @behaviour Phlox.Interceptor

        @impl true
        def before_exec(prep_res, ctx) do
          case lookup_cache(prep_res, ctx.interceptor_opts) do
            {:hit, value} -> {:skip, value}
            :miss         -> {:cont, prep_res}
          end
        end

        @impl true
        def after_exec(exec_res, ctx) do
          store_cache(ctx.prep_res, exec_res, ctx.interceptor_opts)
          {:cont, exec_res}
        end
      end

  ## Context

  Both callbacks receive a context map:

  - `node_id`          — atom id of the node
  - `node_module`      — the node's module
  - `params`           — the node's params
  - `interceptor_opts` — the keyword list passed in the `intercept` declaration
  - `prep_res`         — (in `after_exec` only) the original prep result

  ## Return values

  **`before_exec/2`:**
  - `{:cont, prep_res}` — continue to exec (optionally with modified prep_res)
  - `{:skip, value}` — short-circuit exec entirely, use `value` as exec_res
  - `{:halt, reason}` — abort the flow (raises `Phlox.HaltedError`)

  **`after_exec/2`:**
  - `{:cont, exec_res}` — continue (optionally with modified exec_res)
  - `{:halt, reason}` — abort the flow

  ## Access boundary

  Interceptors can see `prep_res` and `exec_res` but **not** `shared`.
  They cannot change routing (no access to `action`). This is the
  fundamental distinction from middleware — interceptors operate at
  the computation boundary, not the data-flow boundary.

  ## Mental Model

  Middleware                              Interceptors
  ─────────                               ────────────
  before_node(shared, ctx)
    │
    ├── prep(shared, params) → prep_res
    │
    │   ┌─ before_exec(prep_res, ctx) ─┐
    │   │                               │  ← interceptors wrap HERE
    │   │   exec(prep_res, params)      │  ← inside retry loop
    │   │                               │
    │   └─ after_exec(exec_res, ctx) ──┘
    │
    ├── post(shared, prep_res, exec_res, params)
    │
  after_node(shared, action, ctx)
  """

  @typedoc "Context provided to interceptor callbacks."
  @type context :: %{
          node_id: atom(),
          node_module: module(),
          params: map(),
          interceptor_opts: keyword(),
          prep_res: term() | nil
        }

  @doc """
  Called before `exec/2` on each attempt (inside the retry loop).

  Return `{:cont, prep_res}` to proceed, `{:skip, value}` to
  short-circuit exec entirely, or `{:halt, reason}` to abort.
  """
  @callback before_exec(prep_res :: term(), context()) ::
              {:cont, term()} | {:skip, term()} | {:halt, term()}

  @doc """
  Called after `exec/2` returns successfully on each attempt.

  Return `{:cont, exec_res}` to proceed (optionally modified),
  or `{:halt, reason}` to abort.
  """
  @callback after_exec(exec_res :: term(), context()) ::
              {:cont, term()} | {:halt, term()}

  @optional_callbacks [before_exec: 2, after_exec: 2]

  # ---------------------------------------------------------------------------
  # Chain execution
  # ---------------------------------------------------------------------------

  @doc """
  Build an exec function that wraps `mod.exec/2` with the given
  interceptor chain.

  Returns a `(prep_res -> exec_res)` function suitable for use
  inside `Phlox.Retry`.

  When the interceptor list is empty, returns a direct call to
  `mod.exec/2` (zero overhead).
  """
  @spec wrap(module(), atom(), map(), [{module(), keyword()}]) :: (term() -> term())
  def wrap(mod, _node_id, params, []) do
    fn prep_res -> mod.exec(prep_res, params) end
  end

  def wrap(mod, node_id, params, interceptors) do
    fn prep_res ->
      base_ctx = %{
        node_id: node_id,
        node_module: mod,
        params: params,
        interceptor_opts: [],
        prep_res: nil
      }

      case run_before(interceptors, prep_res, base_ctx) do
        {:cont, prep_res} ->
          exec_res = mod.exec(prep_res, params)
          run_after(Enum.reverse(interceptors), exec_res, %{base_ctx | prep_res: prep_res})

        {:skip, value} ->
          value

        {:halt, reason} ->
          raise Phlox.HaltedError,
            reason: reason,
            node_id: node_id,
            middleware: nil,
            phase: :before_exec
      end
    end
  end

  @doc """
  Read interceptor declarations from a node module.

  Returns a list of `{module, opts}` tuples, or `[]` if the module
  has no interceptors declared.
  """
  @spec read_interceptors(module()) :: [{module(), keyword()}]
  def read_interceptors(module) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :__phlox_interceptors__, 0) do
      module.__phlox_interceptors__()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_before([], prep_res, _base_ctx), do: {:cont, prep_res}

  defp run_before([{mw, opts} | rest], prep_res, base_ctx) do
    ctx = %{base_ctx | interceptor_opts: opts}

    if has_callback?(mw, :before_exec, 2) do
      case mw.before_exec(prep_res, ctx) do
        {:cont, prep_res} -> run_before(rest, prep_res, base_ctx)
        {:skip, _} = skip -> skip
        {:halt, _} = halt -> halt
      end
    else
      run_before(rest, prep_res, base_ctx)
    end
  end

  defp run_after([], exec_res, _base_ctx), do: exec_res

  defp run_after([{mw, opts} | rest], exec_res, base_ctx) do
    ctx = %{base_ctx | interceptor_opts: opts}

    if has_callback?(mw, :after_exec, 2) do
      case mw.after_exec(exec_res, ctx) do
        {:cont, exec_res} -> run_after(rest, exec_res, base_ctx)

        {:halt, reason} ->
          raise Phlox.HaltedError,
            reason: reason,
            node_id: base_ctx.node_id,
            middleware: mw,
            phase: :after_exec
      end
    else
      run_after(rest, exec_res, base_ctx)
    end
  end

  defp has_callback?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  # ---------------------------------------------------------------------------
  # Macros (imported by Phlox.Node.__using__)
  # ---------------------------------------------------------------------------

  @doc """
  Declare an interceptor on this node.

  Called inside a `use Phlox.Node` module:

      defmodule MyApp.EmbedNode do
        use Phlox.Node

        intercept MyApp.Interceptor.Cache, ttl: :timer.minutes(5)
        intercept MyApp.Interceptor.RateLimit, max: 10, per: :second

        def exec(text, _params), do: MyLLM.embed(text)
      end

  Interceptors execute in declaration order for `before_exec` and
  reverse order for `after_exec` (onion model).
  """
  defmacro intercept(module, opts \\ []) do
    quote do
      @phlox_interceptors {unquote(module), unquote(opts)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    interceptors =
      env.module
      |> Module.get_attribute(:phlox_interceptors, [])
      |> Enum.reverse()

    quote do
      @doc false
      def __phlox_interceptors__, do: unquote(Macro.escape(interceptors))
    end
  end
end
