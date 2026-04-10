defmodule Mix.Tasks.Phlox.Gen.Migration do
  @shortdoc "Generates the Phlox checkpoints migration"

  @moduledoc """
  Generates an Ecto migration for the `phlox_checkpoints` table.

      $ mix phlox.gen.migration

  This creates a migration file in `priv/repo/migrations/` that sets up
  the append-only checkpoint event log used by `Phlox.Checkpoint.Ecto`.

  ## Options

  - `--repo` — the Ecto.Repo module (default: inferred from your app config)

  ## Table schema

  The migration creates a `phlox_checkpoints` table with:

  - `id` (uuid, primary key)
  - `run_id` (string, indexed) — groups events for one flow execution
  - `sequence` (integer) — monotonic within a run
  - `event_type` (string) — "node_completed", "flow_completed", "flow_errored"
  - `flow_name` (string, nullable) — human-readable flow identifier
  - `node_id` (string) — the node that just completed
  - `next_node_id` (string, nullable) — where to resume (nil = done)
  - `action` (string) — the action returned by post/4
  - `shared_binary` (binary, nullable) — erlang term_to_binary of shared
  - `shared_json` (map/jsonb, nullable) — JSON representation of shared
  - `error_info` (text, nullable) — exception details
  - `inserted_at` (utc_datetime_usec)
  - `updated_at` (utc_datetime_usec)

  Indexes:

  - Unique on `{run_id, sequence}` — enforces append-only semantics
  - Index on `{run_id, event_type}` — powers `list_resumable/1`
  - Index on `{run_id, node_id}` — powers `load_at/3` (rewind)
  """

  use Mix.Task

  @migration_template ~S'''
  defmodule <%= @repo %>.Migrations.CreatePhloxCheckpoints do
    use Ecto.Migration

    def change do
      create table(:phlox_checkpoints, primary_key: false) do
        add :id, :uuid, primary_key: true
        add :run_id, :string, null: false
        add :sequence, :integer, null: false
        add :event_type, :string, null: false
        add :flow_name, :string
        add :node_id, :string, null: false
        add :next_node_id, :string
        add :action, :string, null: false
        add :shared_binary, :binary
        add :shared_json, :map
        add :error_info, :text

        timestamps(type: :utc_datetime_usec)
      end

      # Core constraint: one entry per {run_id, sequence}
      create unique_index(:phlox_checkpoints, [:run_id, :sequence])

      # Powers load_latest/2 and history/2
      create index(:phlox_checkpoints, [:run_id, :inserted_at])

      # Powers list_resumable/1
      create index(:phlox_checkpoints, [:run_id, :event_type])

      # Powers load_at/3 (rewind by node)
      create index(:phlox_checkpoints, [:run_id, :node_id])
    end
  end
  '''

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string])

    repo = resolve_repo(opts)
    timestamp = generate_timestamp()
    filename = "#{timestamp}_create_phlox_checkpoints.exs"

    migrations_dir = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_dir)

    filepath = Path.join(migrations_dir, filename)

    content = EEx.eval_string(@migration_template, assigns: [repo: repo])

    if File.exists?(filepath) do
      Mix.shell().error("Migration already exists: #{filepath}")
    else
      # Check if a phlox_checkpoints migration already exists
      existing =
        migrations_dir
        |> File.ls!()
        |> Enum.find(&String.contains?(&1, "create_phlox_checkpoints"))

      if existing do
        Mix.shell().info("""
        A Phlox checkpoints migration already exists:
          #{Path.join(migrations_dir, existing)}

        If you want to regenerate it, delete the existing file first.
        """)
      else
        File.write!(filepath, content)

        Mix.shell().info("""
        Generated Phlox checkpoints migration:
          #{filepath}

        Run `mix ecto.migrate` to create the table.
        """)
      end
    end
  end

  defp resolve_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        # Try to infer from app config
        app = Mix.Project.config()[:app]

        case Application.get_env(app, :ecto_repos) do
          [repo | _] -> inspect(repo)
          _ -> "MyApp.Repo"
        end

      repo_str ->
        repo_str
    end
  end

  defp generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"
end
