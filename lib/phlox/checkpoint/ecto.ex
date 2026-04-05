if Code.ensure_loaded?(Ecto) do
defmodule Phlox.Checkpoint.Ecto do
  @moduledoc """
  An Ecto-backed checkpoint adapter using Postgres as an append-only event log.

  Each node completion appends a row to the `phlox_checkpoints` table.
  Rows are immutable once written — the `{run_id, sequence}` pair has a
  unique index to enforce this.

  ## Setup

  1. Add `:ecto_sql` and `:postgrex` to your deps
  2. Generate the migration: `mix phlox.gen.migration`
  3. Run: `mix ecto.migrate`

  ## Usage

      Phlox.Pipeline.orchestrate(flow, flow.start_id, shared,
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "ingest-2026-04-05",
        metadata: %{
          checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo},
          flow_name: "IngestPipeline"
        }
      )

  ## Options

  All callbacks accept an `opts` keyword list:

  - `repo:` (**required**) — the Ecto.Repo module to use
  - `serializer:` (default `:erlang`) — `:erlang` for lossless term storage,
    `:json` for inspectable JSONB (loses non-JSON-serializable terms)

  ## Serialization

  With `:erlang` (default), `shared` is stored in the `shared_binary` column
  via `:erlang.term_to_binary/1` and restored with `:erlang.binary_to_term/2`
  using `:safe` mode. This preserves atoms, tuples, structs — the full
  Elixir term space.

  With `:json`, `shared` is stored in the `shared_json` JSONB column via
  `Jason.encode!/1` and `Jason.decode!/1`. Keys become strings, tuples
  become lists, atoms become strings. Use this when you need to query
  checkpoint data from SQL or inspect it in pgAdmin.

  ## Cleanup

  Checkpoints are retained indefinitely by default. Implement a periodic
  cleanup job to delete old completed runs:

      Phlox.Checkpoint.Ecto.delete_completed_before(
        DateTime.add(DateTime.utc_now(), -30, :day),
        repo: MyApp.Repo
      )
  """

  use Phlox.Checkpoint

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  # We don't use an Ecto.Schema module — we work with the table directly
  # via Ecto.Adapters.SQL and schemaless queries. This avoids forcing users
  # to have our schema module in their app, and keeps the adapter self-contained.

  @table "phlox_checkpoints"

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl Phlox.Checkpoint
  def save(run_id, checkpoint, opts) do
    repo = fetch_repo!(opts)
    serializer = Keyword.get(opts, :serializer, :erlang)
    now = DateTime.utc_now()

    {shared_binary, shared_json} = serialize_shared(checkpoint.shared, serializer)

    fields = %{
      id: generate_uuid(),
      run_id: run_id,
      sequence: checkpoint.sequence,
      event_type: to_string(checkpoint.event_type),
      flow_name: checkpoint[:flow_name],
      node_id: to_string(checkpoint.node_id),
      next_node_id: if(checkpoint.next_node_id, do: to_string(checkpoint.next_node_id)),
      action: to_string(checkpoint.action),
      shared_binary: shared_binary,
      shared_json: shared_json,
      error_info: checkpoint[:error_info],
      inserted_at: now,
      updated_at: now
    }

    case repo.insert_all(@table, [fields], on_conflict: :nothing, conflict_target: [:run_id, :sequence]) do
      {1, _} -> :ok
      {0, _} -> :ok  # idempotent — duplicate {run_id, sequence} is fine
    end
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def load_latest(run_id, opts) do
    repo = fetch_repo!(opts)
    serializer = Keyword.get(opts, :serializer, :erlang)

    import Ecto.Query

    query =
      from(c in @table,
        where: c.run_id == ^run_id,
        order_by: [desc: c.sequence],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row_to_checkpoint(row, serializer)}
    end
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def load_at(run_id, node_id, opts) do
    repo = fetch_repo!(opts)
    serializer = Keyword.get(opts, :serializer, :erlang)
    sequence = Keyword.get(opts, :sequence)
    node_id_str = to_string(node_id)

    import Ecto.Query

    query =
      from(c in @table,
        where: c.run_id == ^run_id and c.node_id == ^node_id_str
      )

    query =
      if sequence do
        from(c in query, where: c.sequence == ^sequence)
      else
        from(c in query, order_by: [desc: c.sequence], limit: 1)
      end

    case repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row_to_checkpoint(row, serializer)}
    end
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def history(run_id, opts) do
    repo = fetch_repo!(opts)
    serializer = Keyword.get(opts, :serializer, :erlang)

    import Ecto.Query

    query =
      from(c in @table,
        where: c.run_id == ^run_id,
        order_by: [asc: c.sequence]
      )

    rows = repo.all(query)
    {:ok, Enum.map(rows, &row_to_checkpoint(&1, serializer))}
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def list_resumable(opts) do
    repo = fetch_repo!(opts)
    serializer = Keyword.get(opts, :serializer, :erlang)

    import Ecto.Query

    # Subquery: max sequence per run_id
    latest_seq =
      from(c in @table,
        group_by: c.run_id,
        select: %{run_id: c.run_id, max_seq: max(c.sequence)}
      )

    # Join back to get the full row, filter to :node_completed
    query =
      from(c in @table,
        join: l in subquery(latest_seq),
        on: c.run_id == l.run_id and c.sequence == l.max_seq,
        where: c.event_type == "node_completed",
        order_by: [desc: c.inserted_at]
      )

    rows = repo.all(query)
    {:ok, Enum.map(rows, &row_to_checkpoint(&1, serializer))}
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def delete(run_id, opts) do
    repo = fetch_repo!(opts)

    import Ecto.Query

    from(c in @table, where: c.run_id == ^run_id)
    |> repo.delete_all()

    :ok
  rescue
    e -> {:error, e}
  end

  @impl Phlox.Checkpoint
  def next_sequence(run_id, opts) do
    repo = fetch_repo!(opts)

    import Ecto.Query

    query =
      from(c in @table,
        where: c.run_id == ^run_id,
        select: max(c.sequence)
      )

    case repo.one(query) do
      nil -> {:ok, 1}
      max_seq -> {:ok, max_seq + 1}
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Bonus: cleanup helper
  # ---------------------------------------------------------------------------

  @doc """
  Delete all checkpoints for completed flows that finished before `before_dt`.

  Useful for periodic cleanup of old checkpoint data:

      # Delete checkpoints for flows that completed more than 30 days ago
      Phlox.Checkpoint.Ecto.delete_completed_before(
        DateTime.add(DateTime.utc_now(), -30, :day),
        repo: MyApp.Repo
      )
  """
  @spec delete_completed_before(DateTime.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_completed_before(%DateTime{} = before_dt, opts) do
    repo = fetch_repo!(opts)

    import Ecto.Query

    # Find run_ids where the latest event is flow_completed and inserted before cutoff
    latest_seq =
      from(c in @table,
        group_by: c.run_id,
        select: %{run_id: c.run_id, max_seq: max(c.sequence)}
      )

    completed_run_ids =
      from(c in @table,
        join: l in subquery(latest_seq),
        on: c.run_id == l.run_id and c.sequence == l.max_seq,
        where: c.event_type == "flow_completed" and c.inserted_at < ^before_dt,
        select: c.run_id
      )

    {count, _} =
      from(c in @table, where: c.run_id in subquery(completed_run_ids))
      |> repo.delete_all()

    {:ok, count}
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_repo!(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} -> repo
      :error ->
        raise ArgumentError,
              "Phlox.Checkpoint.Ecto requires a :repo option, e.g. " <>
                "checkpoint: {Phlox.Checkpoint.Ecto, repo: MyApp.Repo}"
    end
  end

  defp serialize_shared(shared, :erlang) do
    {:erlang.term_to_binary(shared), nil}
  end

  defp serialize_shared(shared, :json) do
    {nil, Jason.encode!(shared)}
  end

  defp deserialize_shared(%{shared_binary: bin}, :erlang) when is_binary(bin) do
    :erlang.binary_to_term(bin, [:safe])
  end

  defp deserialize_shared(%{shared_json: json}, :json) when not is_nil(json) do
    Jason.decode!(json, keys: :atoms)
  end

  defp deserialize_shared(%{shared_binary: bin}, _) when is_binary(bin) do
    # Fallback: if binary is present, use it regardless of serializer setting
    :erlang.binary_to_term(bin, [:safe])
  end

  defp deserialize_shared(%{shared_json: json}, _) when not is_nil(json) do
    Jason.decode!(json, keys: :atoms)
  end

  defp deserialize_shared(_, _), do: %{}

  defp row_to_checkpoint(row, serializer) do
    %{
      run_id: row.run_id,
      sequence: row.sequence,
      event_type: String.to_existing_atom(row.event_type),
      flow_name: row.flow_name,
      node_id: String.to_existing_atom(row.node_id),
      next_node_id: if(row.next_node_id, do: String.to_existing_atom(row.next_node_id)),
      action: safe_to_atom_or_string(row.action),
      shared: deserialize_shared(row, serializer),
      error_info: row.error_info,
      inserted_at: row.inserted_at
    }
  end

  defp safe_to_atom_or_string("default"), do: :default
  defp safe_to_atom_or_string(str), do: str

  defp generate_uuid do
    # Simple UUID v4 without a dep. 16 random bytes formatted as 8-4-4-4-12.
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<
        binary_part(hex, 0, 8)::binary, "-",
        binary_part(hex, 8, 4)::binary, "-",
        binary_part(hex, 12, 4)::binary, "-",
        binary_part(hex, 16, 4)::binary, "-",
        binary_part(hex, 20, 12)::binary
      >>
    end)
  end
end
end
