defmodule Phlox.Checkpoint.Memory do
  @moduledoc """
  An in-memory checkpoint adapter backed by an Agent.

  Useful for testing, development, and short-lived flows where
  durability isn't needed. Checkpoints are lost when the Agent
  process stops.

  ## Usage

      # Start the agent (once, e.g. in test setup or Application.start)
      {:ok, _pid} = Phlox.Checkpoint.Memory.start_link()

      # Wire into pipeline
      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [Phlox.Middleware.Checkpoint],
        metadata: %{checkpoint: {Phlox.Checkpoint.Memory, []}}
      )

  ## Options

  The `opts` keyword is accepted for API compatibility but ignored —
  all state lives in the named Agent process.
  """

  use Phlox.Checkpoint

  @agent __MODULE__

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start the in-memory store.

  ## Options

  - `name:` — Agent name (default: `Phlox.Checkpoint.Memory`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @agent)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc "Stop the in-memory store."
  def stop(name \\ @agent) do
    Agent.stop(name)
  end

  @doc "Clear all checkpoints without stopping the agent."
  def clear(name \\ @agent) do
    Agent.update(name, fn _state -> %{} end)
  end

  # ---------------------------------------------------------------------------
  # Phlox.Checkpoint callbacks
  # ---------------------------------------------------------------------------

  @impl Phlox.Checkpoint
  def save(run_id, checkpoint, _opts \\ []) do
    entry = Map.put(checkpoint, :inserted_at, DateTime.utc_now())

    Agent.update(@agent, fn state ->
      entries = Map.get(state, run_id, [])
      Map.put(state, run_id, entries ++ [entry])
    end)

    :ok
  end

  @impl Phlox.Checkpoint
  def load_latest(run_id, _opts \\ []) do
    Agent.get(@agent, fn state ->
      case Map.get(state, run_id, []) do
        [] -> {:error, :not_found}
        entries -> {:ok, List.last(entries)}
      end
    end)
  end

  @impl Phlox.Checkpoint
  def load_at(run_id, node_id, opts \\ []) do
    sequence = Keyword.get(opts, :sequence)

    Agent.get(@agent, fn state ->
      entries = Map.get(state, run_id, [])

      result =
        entries
        |> Enum.filter(fn entry -> entry.node_id == node_id end)
        |> then(fn
          [] ->
            nil

          matches when not is_nil(sequence) ->
            Enum.find(matches, fn e -> e.sequence == sequence end)

          matches ->
            List.last(matches)
        end)

      case result do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end)
  end

  @impl Phlox.Checkpoint
  def history(run_id, _opts \\ []) do
    Agent.get(@agent, fn state ->
      {:ok, Map.get(state, run_id, [])}
    end)
  end

  @impl Phlox.Checkpoint
  def list_resumable(_opts \\ []) do
    Agent.get(@agent, fn state ->
      resumable =
        state
        |> Enum.map(fn {_run_id, entries} -> List.last(entries) end)
        |> Enum.filter(fn entry -> entry.event_type == :node_completed end)

      {:ok, resumable}
    end)
  end

  @impl Phlox.Checkpoint
  def delete(run_id, _opts \\ []) do
    Agent.update(@agent, fn state -> Map.delete(state, run_id) end)
    :ok
  end

  @impl Phlox.Checkpoint
  def next_sequence(run_id, _opts \\ []) do
    Agent.get(@agent, fn state ->
      case Map.get(state, run_id, []) do
        [] -> {:ok, 1}
        entries -> {:ok, length(entries) + 1}
      end
    end)
  end
end
