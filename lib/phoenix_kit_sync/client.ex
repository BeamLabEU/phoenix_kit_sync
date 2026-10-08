defmodule PhoenixKitSync.Client do
  @moduledoc """
  Synchronous client for connecting to a remote DB Sync sender.

  This module provides a clean, synchronous API for programmatic data sync.
  It wraps the asynchronous WebSocketClient to provide blocking operations
  suitable for scripts, migrations, or AI agent use.

  ## Usage

      # Connect to a remote sender
      {:ok, client} = PhoenixKitSync.Client.connect("https://sender.com", "ABC12345")

      # List available tables
      {:ok, tables} = PhoenixKitSync.Client.list_tables(client)

      # Get table schema
      {:ok, schema} = PhoenixKitSync.Client.get_schema(client, "users")

      # Fetch records with pagination
      {:ok, result} = PhoenixKitSync.Client.fetch_records(client, "users", limit: 100)
      # => %{records: [...], has_more: true, offset: 0}

      # Transfer all records from a table (with auto-pagination)
      {:ok, result} = PhoenixKitSync.Client.transfer(client, "users", strategy: :skip)
      # => %{created: 50, updated: 0, skipped: 5, errors: []}

      # Disconnect when done
      :ok = PhoenixKitSync.Client.disconnect(client)

  ## Connection Options

  - `:timeout` - Connection timeout in milliseconds (default: 30_000)
  - `:receiver_info` - Map of receiver identity info to send to sender

  ## Transfer Options

  - `:strategy` - Conflict resolution (`:skip`, `:overwrite`, `:merge`, `:append`)
  - `:batch_size` - Records per batch (default: 500); values above 1000 are
    capped at 1000, the most a sender returns per request
  - `:create_missing_tables` - Auto-create tables that don't exist (default: true)
  """

  alias PhoenixKitSync
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.WebSocketClient

  require Logger

  @default_timeout 30_000
  @default_batch_size 500

  @type client :: pid()
  @type connect_opts :: [
          timeout: pos_integer(),
          receiver_info: map()
        ]
  @type transfer_opts :: [
          strategy: :skip | :overwrite | :merge | :append,
          batch_size: pos_integer(),
          create_missing_tables: boolean()
        ]

  # ===========================================
  # CONNECTION
  # ===========================================

  @doc """
  Connects to a remote DB Sync sender.

  ## Parameters

  - `url` - The sender's base URL (e.g., "https://sender.com")
  - `code` - The connection code from the sender
  - `opts` - Connection options

  ## Options

  - `:timeout` - Connection timeout in ms (default: 30_000)
  - `:receiver_info` - Map of receiver identity info

  ## Returns

  - `{:ok, client}` - Connected client PID
  - `{:error, reason}` - Connection failed

  ## Examples

      {:ok, client} = Client.connect("https://example.com", "ABC12345")

      {:ok, client} = Client.connect("https://example.com", "ABC12345",
        timeout: 60_000,
        receiver_info: %{project: "MyApp", user: "admin@example.com"}
      )
  """
  @spec connect(String.t(), String.t(), connect_opts()) :: {:ok, client()} | {:error, any()}
  def connect(url, code, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    receiver_info = Keyword.get(opts, :receiver_info, %{})

    case WebSocketClient.start_link(
           url: url,
           code: code,
           caller: self(),
           receiver_info: receiver_info
         ) do
      {:ok, pid} ->
        wait_for_connection(pid, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Disconnects from the remote sender.

  ## Examples

      :ok = Client.disconnect(client)
  """
  @spec disconnect(client()) :: :ok
  def disconnect(client) do
    WebSocketClient.disconnect(client)
    :ok
  end

  @doc """
  Checks if the client is still connected.
  """
  @spec connected?(client()) :: boolean()
  def connected?(client) do
    Process.alive?(client)
  end

  # ===========================================
  # DATA INSPECTION
  # ===========================================

  @doc """
  Lists all available tables on the remote sender.

  ## Examples

      {:ok, tables} = Client.list_tables(client)
      # => [%{"name" => "users", "estimated_count" => 150}, ...]
  """
  @spec list_tables(client(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def list_tables(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    WebSocketClient.request_tables(client)
    wait_for_response(:tables, timeout)
  end

  @doc """
  Gets the schema for a table on the remote sender.

  ## Examples

      {:ok, schema} = Client.get_schema(client, "users")
      # => %{table: "users", columns: [...], primary_key: ["id"]}
  """
  @spec get_schema(client(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_schema(client, table, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    WebSocketClient.request_schema(client, table)
    wait_for_response({:schema, table}, timeout)
  end

  @doc """
  Gets the record count for a table on the remote sender.

  ## Examples

      {:ok, count} = Client.get_count(client, "users")
      # => 150
  """
  @spec get_count(client(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_count(client, table, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    WebSocketClient.request_count(client, table)
    wait_for_response({:count, table}, timeout)
  end

  @doc """
  Fetches a batch of records from a table on the remote sender.

  ## Options

  - `:offset` - Number of records to skip (default: 0)
  - `:limit` - Maximum records to return (default: 100)
  - `:timeout` - Request timeout in ms (default: 30_000)

  ## Returns

      {:ok, %{records: [...], offset: 0, has_more: true}}

  ## Examples

      {:ok, result} = Client.fetch_records(client, "users", limit: 50, offset: 0)
  """
  @spec fetch_records(client(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def fetch_records(client, table, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 100)

    WebSocketClient.request_records(client, table, offset: offset, limit: limit)
    wait_for_response({:records, table}, timeout)
  end

  # ===========================================
  # DATA TRANSFER
  # ===========================================

  @doc """
  Transfers all records from a table on the remote sender to the local database.

  This is a high-level function that:
  1. Gets the table schema from the sender
  2. Creates the table locally if it doesn't exist (optional)
  3. Fetches all records with auto-pagination
  4. Imports records with the specified conflict strategy

  ## Options

  - `:strategy` - Conflict resolution (`:skip`, `:overwrite`, `:merge`, `:append`)
  - `:batch_size` - Records per batch (default: 500); values above 1000 are
    capped at 1000, the most a sender returns per request
  - `:create_missing_tables` - Auto-create tables that don't exist (default: true)
  - `:timeout` - Timeout per request in ms (default: 30_000)

  ## Returns

      {:ok, %{created: 50, updated: 0, skipped: 5, errors: []}}

  ## Examples

      {:ok, result} = Client.transfer(client, "users", strategy: :skip)

      {:ok, result} = Client.transfer(client, "posts",
        strategy: :overwrite,
        batch_size: 1000,
        create_missing_tables: true
      )
  """
  @spec transfer(client(), String.t(), transfer_opts()) ::
          {:ok, PhoenixKitSync.DataImporter.import_result()} | {:error, any()}
  def transfer(client, table, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :skip)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    create_missing = Keyword.get(opts, :create_missing_tables, true)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, schema} <- get_schema(client, table, timeout: timeout),
         :ok <- maybe_create_table(table, schema, create_missing) do
      fetch_and_import_all(client, table, strategy, batch_size, timeout)
    end
  end

  @doc """
  Transfers multiple tables from the remote sender.

  ## Options

  - `:tables` - List of table names to transfer (default: all tables)
  - `:strategy` - Conflict resolution for all tables
  - `:strategies` - Map of table name to strategy (overrides `:strategy`)
  - Other options passed to `transfer/3`

  ## Returns

      {:ok, %{"users" => %{created: 50, ...}, "posts" => %{created: 100, ...}}}

  ## Examples

      {:ok, results} = Client.transfer_all(client, strategy: :skip)

      {:ok, results} = Client.transfer_all(client,
        tables: ["users", "posts"],
        strategies: %{"users" => :skip, "posts" => :overwrite}
      )
  """
  @spec transfer_all(client(), keyword()) :: {:ok, map()} | {:error, any()}
  def transfer_all(client, opts \\ []) do
    tables_opt = Keyword.get(opts, :tables)
    default_strategy = Keyword.get(opts, :strategy, :skip)
    strategies = Keyword.get(opts, :strategies, %{})

    with {:ok, all_tables} <- list_tables(client, opts) do
      tables = filter_tables(all_tables, tables_opt)

      results =
        Enum.reduce(tables, %{}, fn table_info, acc ->
          table = table_info["name"]
          strategy = Map.get(strategies, table, default_strategy)

          Logger.info("Sync.Client: Transferring table #{table} with strategy #{strategy}")

          transfer_and_collect(client, table, opts, strategy, acc)
        end)

      {:ok, results}
    end
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp filter_tables(all_tables, nil), do: all_tables

  defp filter_tables(all_tables, tables_opt),
    do: Enum.filter(all_tables, fn t -> t["name"] in tables_opt end)

  defp transfer_and_collect(client, table, opts, strategy, acc) do
    case transfer(client, table, Keyword.put(opts, :strategy, strategy)) do
      {:ok, result} ->
        Map.put(acc, table, result)

      {:error, reason} ->
        Map.put(acc, table, %{error: reason})
    end
  end

  defp wait_for_connection(pid, timeout) do
    receive do
      {:sync_client, :connected} ->
        {:ok, pid}

      {:sync_client, {:error, reason}} ->
        {:error, reason}

      {:sync_client, {:disconnected, reason}} ->
        {:error, {:disconnected, reason}}
    after
      timeout ->
        WebSocketClient.disconnect(pid)
        {:error, :connection_timeout}
    end
  end

  defp wait_for_response(expected_type, timeout) do
    receive do
      {:sync_client, {:tables, tables}} when expected_type == :tables ->
        {:ok, tables}

      {:sync_client, {:schema, table, schema}} when expected_type == {:schema, table} ->
        {:ok, schema}

      {:sync_client, {:count, table, count}} when expected_type == {:count, table} ->
        {:ok, count}

      {:sync_client, {:records, table, result}} when expected_type == {:records, table} ->
        {:ok, result}

      {:sync_client, {:request_error, ^expected_type, error}} ->
        {:error, error}

      {:sync_client, {:error, error}} ->
        {:error, error}

      {:sync_client, :disconnected} ->
        {:error, :disconnected}

      {:sync_client, {:disconnected, reason}} ->
        {:error, {:disconnected, reason}}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp maybe_create_table(table, schema, true = _create_missing) do
    if PhoenixKitSync.table_exists?(table) do
      :ok
    else
      Logger.info("Sync.Client: Creating missing table #{table}")
      PhoenixKitSync.create_table(table, schema)
    end
  end

  defp maybe_create_table(table, _schema, false = _create_missing) do
    if PhoenixKitSync.table_exists?(table) do
      :ok
    else
      {:error, {:table_not_found, table}}
    end
  end

  defp fetch_and_import_all(client, table, strategy, batch_size, timeout) do
    # A sender returns at most DataExporter's maximum per request; asking
    # for more only makes its has_more hint wrong.
    max_batch = DataExporter.max_limit()

    if batch_size > max_batch do
      Logger.debug("Sync.Client: batch_size #{batch_size} capped at #{max_batch} for #{table}")
    end

    loop_state = %{
      client: client,
      table: table,
      strategy: strategy,
      batch_size: min(batch_size, max_batch),
      timeout: timeout
    }

    fetch_and_import_loop(loop_state, 0, %{
      created: 0,
      updated: 0,
      skipped: 0,
      errors: []
    })
  end

  defp fetch_and_import_loop(state, offset, acc) do
    %{client: client, table: table, batch_size: batch_size, timeout: timeout} = state

    case fetch_records(client, table, offset: offset, limit: batch_size, timeout: timeout) do
      {:ok, %{records: records}} when records != [] ->
        import_and_continue(state, offset, acc, records)

      {:ok, %{records: []}} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reads on until an empty page. The sender's has_more is not trusted to
  # end the table: a sender with a lower cap (a connection's
  # max_records_per_request, another version) returns fewer records than
  # asked and may still say there are no more. The price is one extra
  # request per table.
  defp import_and_continue(state, offset, acc, records) do
    case PhoenixKitSync.import_records(state.table, records, state.strategy) do
      {:ok, result} ->
        # Advance by what arrived, not by what was asked.
        fetch_and_import_loop(state, offset + length(records), merge_results(acc, result))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_results(acc, result) do
    %{
      created: acc.created + result.created,
      updated: acc.updated + result.updated,
      skipped: acc.skipped + result.skipped,
      errors: acc.errors ++ result.errors
    }
  end
end
