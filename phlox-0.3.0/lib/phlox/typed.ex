defmodule Phlox.Typed do
  @moduledoc """
  Declares typed contracts on a node's `shared` state boundaries.

  `use Phlox.Typed` gives a node two declarative macros — `input` and
  `output` — that define what `shared` must look like *entering* the
  node (before `prep/2`) and *leaving* it (after `post/4`).

  ## With Gladius (recommended)

      defmodule MyApp.EmbedNode do
        use Phlox.Node
        use Phlox.Typed

        import Gladius

        input open_schema(%{
          required(:text)     => string(:filled?),
          required(:language) => string(:filled?)
        })

        output open_schema(%{
          required(:text)      => string(:filled?),
          required(:language)  => string(:filled?),
          required(:embedding) => list_of(spec(is_list()))
        })

        def prep(shared, _p), do: {shared.text, shared.language}
        def exec({text, lang}, _p), do: MyLLM.embed(text, lang)
        def post(shared, _p, emb, _p2), do: {:default, Map.put(shared, :embedding, emb)}
      end

  ## With Gladius registry refs

      input Gladius.ref(:embed_input_spec)
      output Gladius.ref(:embed_output_spec)

  Registry refs are resolved lazily at validation time via
  `Gladius.Registry.fetch!/1`, so the spec doesn't need to exist
  at compile time.

  ## Without Gladius (plain predicates)

  When Gladius is not a dependency, specs can be plain functions
  that accept a map and return `:ok` or `{:error, term()}`:

      input fn shared ->
        if is_binary(shared[:text]) and is_binary(shared[:language]),
          do: :ok,
          else: {:error, "missing :text or :language"}
      end

  ## How validation works

  Specs are stored as module attributes (`@phlox_input_spec`,
  `@phlox_output_spec`) and read at runtime by
  `Phlox.Middleware.Validate`. The middleware is opt-in — specs on
  nodes are inert unless the middleware is in the pipeline:

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [
          Phlox.Middleware.Validate,
          Phlox.Middleware.Checkpoint
        ]
      )

  When no spec is declared on a node, validation is silently skipped
  for that boundary. A node can declare only `input`, only `output`,
  or both.

  ## Shaped values replace shared

  When using Gladius specs, `Gladius.conform/2` returns a *shaped*
  value — coercions, transforms, and defaults are applied. The
  middleware replaces `shared` with the shaped output. This means
  Gladius specs actively shape flowing data, not just validate it.

  ## Design note

  `input`/`output` validate `shared` at the middleware level (before
  prep, after post). Per-exec validation (`prep_res` entering exec,
  `exec_res` leaving exec) is an interceptor-level concern planned
  for V2.9.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Phlox.Typed, only: [input: 1, output: 1]
    end
  end

  @doc """
  Declare the expected shape of `shared` before this node runs.

  Accepts any Gladius conformable (schema, spec, ref, etc.) or a
  plain `(map() -> :ok | {:error, term()})` function.
  """
  defmacro input(spec) do
    quote do
      @doc false
      def __phlox_input_spec__, do: unquote(spec)
    end
  end

  @doc """
  Declare the expected shape of `shared` after this node runs.

  Accepts any Gladius conformable (schema, spec, ref, etc.) or a
  plain `(map() -> :ok | {:error, term()})` function.
  """
  defmacro output(spec) do
    quote do
      @doc false
      def __phlox_output_spec__, do: unquote(spec)
    end
  end


  # ---------------------------------------------------------------------------
  # Runtime helpers (used by Phlox.Middleware.Validate)
  # ---------------------------------------------------------------------------

  @doc """
  Read a spec from a node module, or `nil` if not declared.

  Checks for the generated `__phlox_input_spec__/0` or
  `__phlox_output_spec__/0` function. Returns `nil` if the module
  doesn't use `Phlox.Typed` or the spec wasn't declared.
  """
  @spec read_spec(module(), :input | :output) :: term() | nil
  def read_spec(module, direction) do
    fun_name =
      case direction do
        :input -> :__phlox_input_spec__
        :output -> :__phlox_output_spec__
      end

    Code.ensure_loaded?(module)

    if function_exported?(module, fun_name, 0) do
      apply(module, fun_name, [])
    else
      nil
    end
  end

  @doc """
  Validate a value against a spec.

  Dispatches to Gladius when available, falls back to plain function
  invocation. Returns `{:ok, shaped_value}` or `{:error, errors}`.

  ## Gladius dispatch

  When the spec is a Gladius conformable struct (`%Gladius.Schema{}`,
  `%Gladius.Spec{}`, `%Gladius.Ref{}`, etc.), calls
  `Gladius.conform/2`. On success, returns the shaped (conformed)
  value. On failure, returns the list of `%Gladius.Error{}` structs.

  ## Plain function dispatch

  When the spec is a function, calls `spec.(value)` and expects
  `:ok` or `{:error, reason}`.
  """
  @spec validate(term(), term()) :: {:ok, term()} | {:error, term()}
  def validate(value, spec) when is_function(spec, 1) do
    case spec.(value) do
      :ok -> {:ok, value}
      {:ok, shaped} -> {:ok, shaped}
      {:error, _} = err -> err
    end
  end

  def validate(value, spec) do
    if gladius_available?() do
      case Gladius.conform(spec, value) do
        {:ok, shaped} -> {:ok, shaped}
        {:error, errors} -> {:error, errors}
      end
    else
      raise ArgumentError,
            "Phlox.Typed received a non-function spec but Gladius is not available. " <>
              "Add {:gladius, \"~> 0.6\"} to your deps, or use a plain function spec."
    end
  end

  @doc false
  def gladius_available? do
    Code.ensure_loaded?(Gladius) and function_exported?(Gladius, :conform, 2)
  end
end
