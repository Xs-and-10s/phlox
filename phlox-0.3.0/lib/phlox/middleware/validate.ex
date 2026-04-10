defmodule Phlox.Middleware.Validate do
  @moduledoc """
  A `Phlox.Middleware` that enforces `input` and `output` specs
  declared via `Phlox.Typed` at node boundaries.

  ## What it validates

  - **Before each node** (`before_node`): reads the node module's
    `input` spec and validates `shared` against it. If validation
    fails, the flow halts with a `{:validation_error, ...}` reason.

  - **After each node** (`after_node`): reads the node module's
    `output` spec and validates the updated `shared` against it.

  ## Shaped values replace shared

  When using Gladius specs, `Gladius.conform/2` returns shaped data —
  coercions, transforms, and defaults are applied. On successful
  validation, the middleware replaces `shared` with the shaped value.
  This means specs actively participate in data flow, not just guard it.

  For plain function specs, `shared` passes through unchanged on success.

  ## Skipping

  When a node has no `input` or `output` spec (i.e., doesn't
  `use Phlox.Typed` or only declares one direction), the missing
  boundary is silently skipped. This makes the middleware safe to
  include globally — untyped nodes work as before.

  ## Usage

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [
          Phlox.Middleware.Validate,    # checks specs
          Phlox.Middleware.Checkpoint   # saves state
        ]
      )

  ## Middleware ordering

  Place `Validate` **before** `Checkpoint` in the middleware list.
  This way, the checkpoint captures post-validation shaped data
  (not raw pre-validation data).

  Since `before_node` runs in list order, `Validate` checks the
  input spec before any other middleware touches shared.

  Since `after_node` runs in reverse list order, `Validate` checks
  the output spec after Checkpoint has saved — but because Validate
  is earlier in the list, its `after_node` actually runs *last*,
  meaning it validates the final shaped shared.

  ## Error format

  Halts with:

      {:halt, {:validation_error, node_id, direction, errors}}

  Where `direction` is `:input` or `:output`, and `errors` is
  either a list of `%Gladius.Error{}` structs (when using Gladius)
  or the term returned by the plain function spec.
  """

  @behaviour Phlox.Middleware

  alias Phlox.Typed

  @impl Phlox.Middleware
  def before_node(shared, ctx) do
    case Typed.read_spec(ctx.node.module, :input) do
      nil ->
        {:cont, shared}

      spec ->
        case Typed.validate(shared, spec) do
          {:ok, shaped} ->
            {:cont, shaped}

          {:error, errors} ->
            {:halt, {:validation_error, ctx.node_id, :input, errors}}
        end
    end
  end

  @impl Phlox.Middleware
  def after_node(shared, action, ctx) do
    case Typed.read_spec(ctx.node.module, :output) do
      nil ->
        {:cont, shared, action}

      spec ->
        case Typed.validate(shared, spec) do
          {:ok, shaped} ->
            {:cont, shaped, action}

          {:error, errors} ->
            {:halt, {:validation_error, ctx.node_id, :output, errors}}
        end
    end
  end
end
