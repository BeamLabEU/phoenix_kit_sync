defmodule PhoenixKitSync.SessionStore do
  @moduledoc """
  ETS-based session storage for DB Sync module.

  Stores sync sessions in ETS for fast, ephemeral access.
  Sessions remain valid as long as the owning LiveView process is alive.
  When the LiveView terminates (page closed), the session is automatically deleted.

  ## Architecture

  This module uses a GenServer to manage an ETS table. The ETS table
  provides fast reads while the GenServer handles process monitoring
  and automatic cleanup when LiveView processes terminate.

  ## Future Migration Path

  This module is designed to be easily replaced with database persistence
  if audit logging or sync history is needed. The public API would remain
  the same, only the storage backend would change.

  ## Session Structure

      %{
        code: "A7X9K2M4",
        direction: :send | :receive,
        status: :pending | :connected | :completed | :failed,
        owner_pid: #PID<0.123.0>,     # Session is deleted when this process dies
        created_at: ~U[2025-12-16 12:15:00Z],
        connected_at: nil | ~U[...],
        sender_info: nil | %{...},
        receiver_info: nil | %{...}
      }

  ## Single use

  A code is claimed once (`claim/2`). That it was claimed is kept apart from
  the session map, in a table of its own that only this process writes, so
  no later `status` (`:completed`, `:failed`, or `:pending` written back by
  `update/2` or `merge/2`) makes the code claimable again. The claim lives
  as long as the session does.
  """

  use GenServer
  alias PhoenixKit.Utils.Date, as: UtilsDate
  require Logger

  @table_name :phoenix_kit_sync_sessions
  @monitors_table :phoenix_kit_sync_monitors
  @claims_table :phoenix_kit_sync_claims
  @cleanup_interval :timer.hours(1)

  # ===========================================
  # PUBLIC API
  # ===========================================

  @doc """
  Starts the SessionStore GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session in the store and monitors the owner process.

  ## Parameters

  - `session` - Map with at least `code` and `owner_pid` fields

  ## Returns

  - `:ok` on success
  - `{:error, :already_exists}` if code already exists
  """
  @spec create(map()) :: :ok | {:error, :already_exists}
  def create(%{code: code, owner_pid: pid} = session) when is_binary(code) and is_pid(pid) do
    case :ets.insert_new(@table_name, {code, session}) do
      true ->
        # Ask GenServer to monitor the owner process
        GenServer.cast(__MODULE__, {:monitor_session, code, pid})
        :ok

      false ->
        {:error, :already_exists}
    end
  end

  def create(%{code: code} = session) when is_binary(code) do
    # Fallback for sessions without owner_pid (backwards compatibility)
    case :ets.insert_new(@table_name, {code, session}) do
      true -> :ok
      false -> {:error, :already_exists}
    end
  end

  @doc """
  Gets a session by its code.

  ## Returns

  - `{:ok, session}` if found
  - `{:error, :not_found}` if not found
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(code) when is_binary(code) do
    case :ets.lookup(@table_name, code) do
      [{^code, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Updates an existing session.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if session doesn't exist
  """
  @spec update(String.t(), map()) :: :ok | {:error, :not_found}
  def update(code, session) when is_binary(code) and is_map(session) do
    case :ets.lookup(@table_name, code) do
      [{^code, _}] ->
        :ets.insert(@table_name, {code, session})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Marks a session as connected, once.

  The check and the write happen in the store's own process, so two callers
  racing on one code cannot both be told it is free. A code is claimed once
  for the life of its session, whatever its status becomes afterwards.

  ## Returns

  - `{:ok, session}` - The session, now `:connected` at `connected_at`
  - `{:error, :already_used}` - It was claimed before
  - `{:error, :not_found}` - No such session
  """
  @spec claim(String.t(), DateTime.t()) ::
          {:ok, map()} | {:error, :already_used | :not_found}
  def claim(code, connected_at) when is_binary(code) do
    GenServer.call(__MODULE__, {:claim, code, connected_at})
  end

  @doc """
  Merges `updates` into an existing session, in the store's own process so
  the merge cannot write back a copy read before a concurrent `claim/2`.

  ## Returns

  - `{:ok, session}` - The merged session
  - `{:error, :not_found}` - No such session
  """
  @spec merge(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def merge(code, updates) when is_binary(code) and is_map(updates) do
    GenServer.call(__MODULE__, {:merge, code, updates})
  end

  @doc """
  Deletes a session by code.
  """
  @spec delete(String.t()) :: :ok
  def delete(code) when is_binary(code) do
    :ets.delete(@table_name, code)
    # The claim goes with its session, in the process that owns the table.
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:forget_claim, code})
    :ok
  end

  @doc """
  Counts active sessions.

  All sessions in the store are active (sessions are deleted when owner process terminates).
  """
  @spec count_active() :: non_neg_integer()
  def count_active do
    :ets.info(@table_name, :size)
  end

  @doc """
  Lists all active sessions.
  Useful for debugging and admin interfaces.

  All sessions in the store are active (sessions are deleted when owner process terminates).
  """
  @spec list_active() :: [map()]
  def list_active do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_code, session} -> session end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  # ===========================================
  # GENSERVER CALLBACKS
  # ===========================================

  @impl true
  def init(_opts) do
    # Create ETS table with public access for fast reads
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Create monitors table to track ref -> code mappings
    :ets.new(@monitors_table, [
      :set,
      :named_table,
      :protected
    ])

    # Codes that were claimed. Written by this process only.
    :ets.new(@claims_table, [:set, :named_table, :protected])

    # Schedule periodic cleanup of orphaned sessions (fallback safety)
    schedule_cleanup()

    Logger.debug("Sync.SessionStore started")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, code, connected_at}, _from, state) do
    reply =
      case :ets.lookup(@table_name, code) do
        # A session connected by other means than a claim is used as well.
        [{^code, %{status: :connected}}] ->
          {:error, :already_used}

        [{^code, session}] ->
          if :ets.insert_new(@claims_table, {code}) do
            claimed = %{session | status: :connected, connected_at: connected_at}
            :ets.insert(@table_name, {code, claimed})
            {:ok, claimed}
          else
            {:error, :already_used}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:merge, code, updates}, _from, state) do
    reply =
      case :ets.lookup(@table_name, code) do
        [{^code, session}] ->
          merged = Map.merge(session, updates)
          :ets.insert(@table_name, {code, merged})
          {:ok, merged}

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:forget_claim, code}, state) do
    # Only once the session is gone: a code deleted and created again
    # between the delete and this message keeps nothing it should not.
    if :ets.lookup(@table_name, code) == [], do: :ets.delete(@claims_table, code)
    {:noreply, state}
  end

  def handle_cast({:monitor_session, code, pid}, state) do
    ref = Process.monitor(pid)
    # Store mapping from monitor ref to session code
    :ets.insert(@monitors_table, {ref, code})
    Logger.debug("Sync.SessionStore: Monitoring #{inspect(pid)} for a session")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Process died, delete the associated session
    case :ets.lookup(@monitors_table, ref) do
      [{^ref, code}] ->
        :ets.delete(@monitors_table, ref)
        :ets.delete(@table_name, code)
        :ets.delete(@claims_table, code)

        Logger.debug("Sync.SessionStore: Session deleted (owner process terminated)")

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_orphaned, state) do
    cleanup_orphaned_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_orphaned, @cleanup_interval)
  end

  defp cleanup_orphaned_sessions do
    # This is a fallback cleanup for any orphaned sessions
    # (e.g., if monitor somehow failed to fire)
    # Sessions without owner_pid or with dead owner_pid are cleaned up

    orphaned =
      :ets.foldl(
        fn {code, session}, acc ->
          if orphaned_session?(session), do: [code | acc], else: acc
        end,
        [],
        @table_name
      )

    # Delete orphaned sessions
    Enum.each(orphaned, fn code ->
      :ets.delete(@table_name, code)
      :ets.delete(@claims_table, code)
    end)

    if orphaned != [] do
      Logger.debug("Sync.SessionStore: Cleaned up #{length(orphaned)} orphaned sessions")
    end
  end

  defp orphaned_session?(session) do
    case Map.get(session, :owner_pid) do
      nil -> session_too_old?(session)
      pid when is_pid(pid) -> not Process.alive?(pid)
    end
  end

  defp session_too_old?(session) do
    case Map.get(session, :created_at) do
      nil ->
        true

      created_at ->
        # Consider sessions older than 24 hours as orphaned
        hours_old = DateTime.diff(UtilsDate.utc_now(), created_at, :hour)
        hours_old > 24
    end
  end
end
