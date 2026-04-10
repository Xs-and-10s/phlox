defmodule Phlox.FlowSupervisor do
  @moduledoc """
  A `DynamicSupervisor` that spawns, supervises, and tracks `Phlox.FlowServer`
  processes by a user-supplied name.

  ## Starting the supervisor

  Add it to your application's supervision tree:

      children = [
        Phlox.FlowSupervisor
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  Or start it directly (useful in tests):

      {:ok, _sup} = Phlox.FlowSupervisor.start_link([])

  ## Spawning flows

      flow = Phlox.Graph.new() |> ... |> Phlox.Graph.to_flow!()

      {:ok, pid} = Phlox.FlowSupervisor.start_flow(:my_flow, flow, %{url: "https://example.com"})

      # Run to completion
      {:ok, result} = Phlox.FlowServer.run(Phlox.FlowSupervisor.server(:my_flow))

      # Inspect mid-run
      %{shared: shared, status: status, flow_id: fid} =
        Phlox.FlowServer.state(Phlox.FlowSupervisor.server(:my_flow))

      # Step through manually
      {:continue, next_id, shared} = Phlox.FlowServer.step(Phlox.FlowSupervisor.server(:my_flow))

  ## With middlewares

      {:ok, _pid} = Phlox.FlowSupervisor.start_flow(:my_flow, flow,
        %{phlox_flow_id: "job-42", url: "https://example.com"},
        middlewares: [Phlox.Middleware.Checkpoint],
        run_id: "job-42",
        metadata: %{flow_name: "IngestPipeline"}
      )

  ## Looking up live flows

      pid = Phlox.FlowSupervisor.whereis(:my_flow)   # nil if not running
      names = Phlox.FlowSupervisor.running()          # [:my_flow, ...]

  ## Stopping flows

      :ok = Phlox.FlowSupervisor.stop_flow(:my_flow)

  ## Restart strategy

  By default, `FlowServer` processes are started with `restart: :temporary` —
  they are not restarted if they crash or complete. This is intentional: a flow
  that has errored should not restart automatically without you supplying fresh
  shared state. Use `reset/2` on the server, then call `run/1` again if you
  want to retry.

  For flows that should survive crashes (long-running agent loops), pass
  `restart: :permanent` to `start_flow/4`.
  """

  use DynamicSupervisor

  alias Phlox.FlowServer

  @registry Phlox.FlowRegistry

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the FlowSupervisor.

  ## Options

  - `max_restarts:` (default `3`) — maximum number of child restarts allowed
    within `max_seconds` before the supervisor itself terminates. Only
    meaningful when individual flows use `restart: :permanent` or
    `restart: :transient`.
  - `max_seconds:` (default `5`) — the sliding window (in seconds) over which
    `max_restarts` is counted.
  - `name:` — registered name (default: `Phlox.FlowSupervisor`).

  ### Tuning for long-running agent loops

      Phlox.FlowSupervisor.start_link(max_restarts: 10, max_seconds: 60)

  ### Tighten for high-churn short flows

      Phlox.FlowSupervisor.start_link(max_restarts: 2, max_seconds: 10)
  """
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gen_opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Spawn a new `FlowServer` under the supervisor, registered under `name`.

  - `name`    — any term usable as a Registry key (atom recommended)
  - `flow`    — a `%Phlox.Flow{}` built with `Phlox.Graph`
  - `shared`  — initial shared state map (default `%{}`)
  - `opts`    — keyword options:
      - `restart:` — `:temporary` (default) | `:permanent` | `:transient`
      - `middlewares:` — list of `Phlox.Middleware` modules (forwarded to FlowServer)
      - `run_id:` — execution identifier (forwarded to FlowServer)
      - `metadata:` — arbitrary map (forwarded to FlowServer)

  Returns `{:ok, pid}` or `{:error, {:already_started, pid}}` if a flow
  with that name is already running.
  """
  @spec start_flow(term(), Phlox.Flow.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_flow(name, flow, shared \\ %{}, opts \\ []) do
    {restart, server_opts} = Keyword.pop(opts, :restart, :temporary)

    child_spec = %{
      id:      {FlowServer, name},
      start:   {FlowServer, :start_link,
                [Keyword.merge(server_opts, flow: flow, shared: shared, name: via(name))]},
      restart: restart,
      type:    :worker
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid}                        -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
      {:error, reason}                  -> {:error, reason}
    end
  end

  @doc """
  Stop and remove a running flow by name.
  Returns `:ok` if stopped, `{:error, :not_found}` if no flow exists with that name.

  Blocks until the process has fully terminated and its Registry entry is removed,
  so `whereis/1` will return `nil` immediately after this call returns.
  """
  @spec stop_flow(term()) :: :ok | {:error, :not_found}
  def stop_flow(name) do
    case whereis(name) do
      nil ->
        {:error, :not_found}

      pid ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(__MODULE__, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> {:error, :timeout}
        end
    end
  end

  @doc """
  Return a via-tuple for the named flow, suitable for passing to any
  `Phlox.FlowServer` function or `GenServer.call/3` directly.

      server = Phlox.FlowSupervisor.server(:my_flow)
      Phlox.FlowServer.run(server)
      Phlox.FlowServer.state(server)
  """
  @spec server(term()) :: {:via, Registry, {atom(), term()}}
  def server(name), do: {:via, Registry, {@registry, name}}

  @doc "Return the pid of a running flow, or `nil` if not found."
  @spec whereis(term()) :: pid() | nil
  def whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      []         -> nil
    end
  end

  @doc "Return the names of all currently running (alive) flows."
  @spec running() :: [term()]
  def running do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_name, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {name, _pid} -> name end)
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callbacks
  # ---------------------------------------------------------------------------

  @impl DynamicSupervisor
  def init(opts) do
    max_restarts = Keyword.get(opts, :max_restarts, 3)
    max_seconds  = Keyword.get(opts, :max_seconds, 5)

    DynamicSupervisor.init(
      strategy:     :one_for_one,
      max_restarts: max_restarts,
      max_seconds:  max_seconds
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp via(name), do: {:via, Registry, {@registry, name}}
end
