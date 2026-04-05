defmodule Phlox.Resume do
  @moduledoc """
  Resume or rewind a checkpointed flow.

  This module provides the user-facing API for continuing a flow from
  a previously saved checkpoint. It loads the checkpoint, validates
  that the target node exists in the flow, and delegates to
  `Phlox.Pipeline.orchestrate/4`.

  ## Resume from latest checkpoint

  Pick up where the flow left off — load the most recent checkpoint
  and continue from its `next_node_id`:

      {:ok, result} = Phlox.Resume.resume("ingest-run-42",
        flow: my_flow,
        checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}
      )

  ## Rewind to a specific node

  Detected a hallucination at node `:embed`? Rewind to the checkpoint
  saved after `:chunk` (the node before `:embed`) and re-execute from
  there:

      {:ok, result} = Phlox.Resume.rewind("ingest-run-42", :chunk,
        flow: my_flow,
        checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}
      )

  ## Middleware continuation

  The checkpoint middleware is automatically included when resuming,
  so the resumed run continues to save checkpoints. Additional
  middlewares can be passed via `:middlewares`:

      {:ok, result} = Phlox.Resume.resume("run-42",
        flow: my_flow,
        checkpoint: {Phlox.Checkpoint.Memory, []},
        middlewares: [MyApp.Middleware.CostTracker]
      )

  ## Options

  - `flow:` (**required**) — the `%Phlox.Flow{}` to resume
  - `checkpoint:` (**required**) — `{adapter_module, adapter_opts}` tuple
  - `middlewares:` — additional middlewares (checkpoint middleware is
    always appended automatically)
  - `run_id:` — override the run_id for the resumed execution
    (defaults to the original run_id, so checkpoints append to the
    same history)
  - `metadata:` — additional metadata merged into the pipeline context
  """

  alias Phlox.Pipeline

  @doc """
  Resume a flow from its latest checkpoint.

  Loads the most recent checkpoint for `run_id` and continues from
  its `next_node_id` with its `shared` state.

  Returns `{:ok, final_shared}` on success, `{:error, reason}` if
  the checkpoint can't be loaded or the flow has already completed.
  """
  @spec resume(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume(run_id, opts) do
    _flow = Keyword.fetch!(opts, :flow)
    {adapter, adapter_opts} = fetch_checkpoint_opt!(opts)

    case adapter.load_latest(run_id, adapter_opts) do
      {:ok, checkpoint} ->
        run_from_checkpoint(run_id, checkpoint, opts)

      {:error, :not_found} ->
        {:error, {:no_checkpoint, run_id}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Rewind a flow to a specific node and re-execute from there.

  Loads the checkpoint saved after `node_id` completed, then resumes
  from its `next_node_id`. This re-executes `node_id`'s successor and
  everything downstream.

  Pass `sequence:` in opts to target a specific iteration when a node
  runs multiple times (e.g. in a loop):

      Phlox.Resume.rewind("run-42", :think, sequence: 3,
        flow: my_flow,
        checkpoint: {Phlox.Checkpoint.Memory, []}
      )
  """
  @spec rewind(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def rewind(run_id, node_id, opts) do
    _flow = Keyword.fetch!(opts, :flow)
    {adapter, adapter_opts} = fetch_checkpoint_opt!(opts)
    sequence = Keyword.get(opts, :sequence)

    load_opts = if sequence, do: [sequence: sequence] ++ adapter_opts, else: adapter_opts

    case adapter.load_at(run_id, node_id, load_opts) do
      {:ok, checkpoint} ->
        run_from_checkpoint(run_id, checkpoint, opts)

      {:error, :not_found} ->
        {:error, {:no_checkpoint_at, run_id, node_id}}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp run_from_checkpoint(run_id, checkpoint, opts) do
    flow = Keyword.fetch!(opts, :flow)
    {adapter, adapter_opts} = fetch_checkpoint_opt!(opts)

    case checkpoint do
      %{next_node_id: nil} ->
        {:error, {:flow_already_completed, run_id}}

      %{next_node_id: next_node_id, shared: shared} ->
        unless Map.has_key?(flow.nodes, next_node_id) do
          raise ArgumentError,
                "Phlox.Resume: checkpoint targets node :#{next_node_id} " <>
                  "but it doesn't exist in the flow. " <>
                  "Known nodes: #{inspect(Map.keys(flow.nodes))}"
        end

        resumed_run_id = Keyword.get(opts, :run_id, run_id)
        extra_middlewares = Keyword.get(opts, :middlewares, [])
        extra_metadata = Keyword.get(opts, :metadata, %{})

        pipeline_opts = [
          run_id: resumed_run_id,
          middlewares: extra_middlewares ++ [Phlox.Middleware.Checkpoint],
          metadata:
            Map.merge(extra_metadata, %{
              checkpoint: {adapter, adapter_opts},
              flow_name: checkpoint[:flow_name],
              resumed_from: %{
                original_run_id: run_id,
                node_id: checkpoint.node_id,
                sequence: checkpoint.sequence
              }
            })
        ]

        try do
          result = Pipeline.orchestrate(flow, next_node_id, shared, pipeline_opts)
          {:ok, result}
        rescue
          e -> {:error, e}
        end
    end
  end

  defp fetch_checkpoint_opt!(opts) do
    case Keyword.fetch(opts, :checkpoint) do
      {:ok, {adapter, adapter_opts}} when is_atom(adapter) and is_list(adapter_opts) ->
        {adapter, adapter_opts}

      {:ok, other} ->
        raise ArgumentError,
              "Expected :checkpoint to be {module, opts}, got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "Phlox.Resume requires a :checkpoint option, e.g. " <>
                "checkpoint: {Phlox.Checkpoint.Memory, []}"
    end
  end
end
