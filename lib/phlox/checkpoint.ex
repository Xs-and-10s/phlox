defmodule Phlox.Checkpoint do
  @moduledoc """
  Behaviour defining the persistence contract for flow checkpoints.

  A checkpoint captures everything needed to resume a flow from a
  specific node: the `shared` state, which node just completed, and
  where to go next. Implementations store and retrieve these snapshots
  using whatever backend suits the application — Ecto/Postgres, ETS,
  Redis, the filesystem, etc.

  ## Append-only event log

  Checkpoints are append-only by design. Each node completion appends
  a new entry with a monotonic `sequence` number. This gives you:

  - **Resume** — load the latest checkpoint for a `run_id`, continue
    from its `next_node_id` with its `shared`
  - **Rewind** — load any earlier checkpoint by sequence or node_id,
    re-execute from that point (e.g. after detecting a hallucination)
  - **Audit trail** — inspect the full history of `shared` state
    transitions for debugging or compliance

  ## Implementing a checkpoint adapter

      defmodule MyApp.Checkpoint.Redis do
        @behaviour Phlox.Checkpoint

        @impl true
        def save(run_id, checkpoint, opts) do
          # Append to a Redis list keyed by run_id
        end

        @impl true
        def load_latest(run_id, opts) do
          # Return the last entry in the list
        end

        # ... etc
      end

  ## Usage with `Phlox.Pipeline`

  Checkpoint adapters are not called directly — they're wired in via
  `Phlox.Middleware.Checkpoint`, which calls `save/3` after each node:

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [Phlox.Middleware.Checkpoint],
        metadata: %{
          checkpoint: {MyApp.Checkpoint.Redis, pool: :default}
        }
      )

  ## Serialization

  The `shared` map may contain arbitrary Elixir terms (atoms, tuples,
  structs). Adapters are responsible for serialization. The recommended
  default is `:erlang.term_to_binary/1` for lossless round-tripping,
  with an optional JSON mode for inspectability at the cost of losing
  non-JSON-serializable terms.
  """

  @typedoc """
  A checkpoint snapshot — everything needed to resume or rewind a flow.

  ## Fields

  - `run_id`       — caller-provided or auto-generated identifier for
                     this flow execution
  - `sequence`     — monotonically increasing integer within a run
                     (1 for the first node completed, 2 for the second, etc.)
  - `event_type`   — what happened: node completed, flow finished, or error
  - `flow_name`    — optional human-readable name for the flow definition
  - `node_id`      — the node that just finished executing
  - `next_node_id` — where the flow should go next (`nil` = flow is done)
  - `action`       — the action string returned by the node's `post/4`
  - `shared`       — the full `shared` map after this node's `post/4`
  - `error_info`   — exception details when `event_type` is `:flow_errored`
  - `inserted_at`  — when this checkpoint was recorded
  """
  @type checkpoint :: %{
          run_id: String.t(),
          sequence: pos_integer(),
          event_type: :node_completed | :flow_completed | :flow_errored,
          flow_name: String.t() | nil,
          node_id: atom(),
          next_node_id: atom() | nil,
          action: atom() | String.t(),
          shared: map(),
          error_info: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @typedoc """
  Adapter-specific options (e.g. `repo: MyApp.Repo`, `pool: :default`).
  """
  @type adapter_opts :: keyword()

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Append a checkpoint entry for the given `run_id`.

  Called by `Phlox.Middleware.Checkpoint` after each node completes.
  The `checkpoint` map contains all fields listed in `t:checkpoint/0`
  except `inserted_at`, which the adapter should set.

  Must be idempotent for the same `{run_id, sequence}` pair — if a
  retry causes a duplicate write, the adapter should upsert or ignore.
  """
  @callback save(
              run_id :: String.t(),
              checkpoint :: map(),
              opts :: adapter_opts()
            ) :: :ok | {:error, term()}

  @doc """
  Load the most recent checkpoint for `run_id`.

  Returns the checkpoint with the highest `sequence` number.
  Used by the resume API to continue a flow from where it left off.
  """
  @callback load_latest(
              run_id :: String.t(),
              opts :: adapter_opts()
            ) :: {:ok, checkpoint()} | {:error, :not_found | term()}

  @doc """
  Load a specific checkpoint for rewind.

  Finds the checkpoint where `node_id` matches — specifically, the
  entry recorded when that node completed. If the node ran multiple
  times (e.g. in a loop), returns the entry at the given `sequence`
  if provided, or the latest one for that node otherwise.

  This is the rewind primitive: load the state from *after* a known-good
  node, then resume from its `next_node_id` to re-execute everything
  downstream.
  """
  @callback load_at(
              run_id :: String.t(),
              node_id :: atom(),
              opts :: adapter_opts()
            ) :: {:ok, checkpoint()} | {:error, :not_found | term()}

  @doc """
  Load all checkpoints for a `run_id`, ordered by sequence.

  Returns the full audit trail of node transitions. Useful for
  debugging, visualization, and compliance.
  """
  @callback history(
              run_id :: String.t(),
              opts :: adapter_opts()
            ) :: {:ok, [checkpoint()]} | {:error, term()}

  @doc """
  List all runs that can be resumed.

  Returns the latest checkpoint for each `run_id` where
  `event_type` is `:node_completed` (i.e. the flow didn't finish).
  """
  @callback list_resumable(opts :: adapter_opts()) ::
              {:ok, [checkpoint()]} | {:error, term()}

  @doc """
  Delete all checkpoints for a `run_id`.

  Called after a flow completes successfully and the caller no longer
  needs the ability to rewind. Also useful for cleanup/TTL sweeps.
  """
  @callback delete(
              run_id :: String.t(),
              opts :: adapter_opts()
            ) :: :ok | {:error, term()}

  @doc """
  Return the next sequence number for a `run_id`.

  Adapters should return `1` if no checkpoints exist for the run,
  or `max(sequence) + 1` otherwise. This is called by the checkpoint
  middleware to assign monotonic sequence numbers.

  A default implementation is provided that calls `load_latest/2`.
  """
  @callback next_sequence(
              run_id :: String.t(),
              opts :: adapter_opts()
            ) :: {:ok, pos_integer()} | {:error, term()}

  @optional_callbacks [next_sequence: 2]

  # ---------------------------------------------------------------------------
  # Default implementations
  # ---------------------------------------------------------------------------

  @doc false
  def __next_sequence_default__(adapter, run_id, opts) do
    case adapter.load_latest(run_id, opts) do
      {:ok, %{sequence: seq}} -> {:ok, seq + 1}
      {:error, :not_found} -> {:ok, 1}
      {:error, _} = err -> err
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Phlox.Checkpoint

      @doc false
      def next_sequence(run_id, opts) do
        Phlox.Checkpoint.__next_sequence_default__(__MODULE__, run_id, opts)
      end

      defoverridable next_sequence: 2
    end
  end
end
