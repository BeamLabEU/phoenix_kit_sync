defmodule PhoenixKitSync.ConnectionNotifier do
  @moduledoc """
  Handles cross-site notification when creating sender connections.

  When a sender connection is created, this module notifies the remote site
  so they can automatically register the incoming connection on their end.

  ## How It Works

  1. When you create a sender connection pointing to a remote site (e.g., "https://remote.com")
  2. This module calls `POST https://remote.com{prefix}/sync/api/register-connection`
     where `{prefix}` mirrors the remote's configured URL prefix (see `remote_url_prefix/0`)
  3. The remote site creates a receiver connection automatically
  4. The result is recorded in the connection's metadata

  ## Remote Site Responses

  - 200 OK - Connection registered successfully
  - 401 Unauthorized - Password required or invalid
  - 403 Forbidden - Incoming connections denied
  - 409 Conflict - Connection already exists
  - 503 Service Unavailable - DB Sync module disabled

  ## Usage

  Usually called automatically when creating connections via the LiveView UI.
  Can also be called manually:

      {:ok, result} = ConnectionNotifier.notify_remote_site(connection, token, password: "optional")
  """

  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitSync.ConnectionNotifier.Prepare
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.ExtensionTypes
  alias PhoenixKitSync.PullFilter
  alias PhoenixKitSync.RateLimit
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Transfers

  @default_timeout 30_000
  @connect_timeout 10_000

  @type notify_result :: %{
          success: boolean(),
          status: :registered | :pending | :failed | :skipped,
          message: String.t(),
          remote_connection_uuid: String.t() | nil,
          http_status: integer() | nil,
          error: String.t() | nil
        }

  @typedoc """
  A connection as these functions read it: the `Connection` struct, or any
  map with `site_url` and `auth_token_hash` under atom or string keys.
  """
  @type connection_ref :: PhoenixKitSync.Connection.t() | map()

  @typedoc """
  What a pull imported: record counts, `unknown_columns` when records
  carried columns the local table lacks, and `truncated: true` when the
  sender stopped short and the pull could not continue, with
  `unsupported_key_type` when the sender named the key type it has no
  cursor for.
  """
  @type pull_result :: %{
          required(:imported) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          required(:errors) => non_neg_integer(),
          optional(:unknown_columns) => [String.t()],
          optional(:truncated) => true,
          optional(:unsupported_key_type) => String.t()
        }

  @typedoc "Sender key to local key, per table: `%{{table, sender_key} => local_key}`."
  @type uuid_remap :: %{optional({String.t(), String.t()}) => term()}

  # A sender's reasons for refusing a request under a connection, by the
  # error_code of its 403.
  @connection_refusals %{
    "connection_not_active" => :connection_not_active,
    "connection_expired" => :connection_expired,
    "download_limit_reached" => :download_limit_reached,
    "record_limit_reached" => :record_limit_reached,
    "ip_not_allowed" => :ip_not_allowed,
    "outside_allowed_hours" => :outside_allowed_hours,
    "invalid_password" => :invalid_password
  }

  @pull_refusals Map.merge(@connection_refusals, %{
                   "invalid_cursor" => :invalid_cursor,
                   "no_primary_key" => :source_without_primary_key
                 })

  @doc """
  Notifies a remote site about a new sender connection.

  ## Parameters

  - `connection` - The sender connection that was just created
  - `raw_token` - The raw auth token (only available at creation time)
  - `opts` - Options:
    - `:password` - Password to provide to remote site (if required)
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, result}` - Notification sent, result contains details
  - `{:error, reason}` - Failed to send notification
  """
  @spec notify_remote_site(map(), String.t(), keyword()) ::
          {:ok, notify_result()} | {:error, any()}
  def notify_remote_site(connection, raw_token, opts \\ []) do
    # Only notify for sender connections
    direction = Map.get(connection, :direction) || Map.get(connection, "direction")

    if direction != "sender" do
      {:ok,
       %{
         success: true,
         status: :skipped,
         message: "Notification skipped for receiver connections",
         remote_connection_uuid: nil,
         http_status: nil,
         error: nil
       }}
    else
      do_notify_remote_site(connection, raw_token, opts)
    end
  end

  defp do_notify_remote_site(connection, raw_token, opts) do
    password = Keyword.get(opts, :password)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Get connection fields (support both atom and string keys)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")
    conn_name = Map.get(connection, :name) || Map.get(connection, "name")
    conn_uuid = Map.get(connection, :uuid) || Map.get(connection, "uuid")

    # Build the API URL
    api_url = build_api_url(site_url)

    # Resolve our URL for the request body
    our_url = get_our_site_url()

    # Build request body
    body = build_request_body(conn_name, our_url, raw_token, password)

    Logger.info(
      "[Sync.Notifier] Creating outgoing connection " <>
        "| connection_uuid=#{conn_uuid} " <>
        "| name=#{inspect(conn_name)} " <>
        "| remote_url=#{site_url} " <>
        "| api_url=#{api_url} " <>
        "| our_url=#{our_url} " <>
        "| has_password=#{password != nil} " <>
        "| timeout=#{timeout}ms"
    )

    case make_http_request(api_url, body, timeout) do
      {:ok, response} ->
        result = parse_response(response)

        Logger.info(
          "[Sync.Notifier] Remote site responded " <>
            "| connection_uuid=#{conn_uuid} " <>
            "| http_status=#{response.status} " <>
            "| success=#{result.success} " <>
            "| result_status=#{result.status} " <>
            "| remote_connection_uuid=#{result.remote_connection_uuid} " <>
            "| message=#{inspect(result.message)}"
        )

        update_connection_metadata(connection, result)
        {:ok, result}

      {:error, reason} ->
        Logger.error(
          "[Sync.Notifier] Failed to contact remote site " <>
            "| connection_uuid=#{conn_uuid} " <>
            "| remote_url=#{site_url} " <>
            "| api_url=#{api_url} " <>
            "| error=#{inspect(reason)}"
        )

        result = %{
          success: false,
          status: :failed,
          message: "Failed to contact remote site",
          remote_connection_uuid: nil,
          http_status: nil,
          error: format_error(reason)
        }

        update_connection_metadata(connection, result)
        {:ok, result}
    end
  end

  @doc """
  Checks the status of a remote site's DB Sync API.

  ## Parameters

  - `site_url` - The remote site's base URL

  ## Returns

  - `{:ok, status}` - Remote site status
  - `{:error, reason}` - Failed to contact site
  """
  @spec check_remote_status(String.t()) :: {:ok, map()} | {:error, any()}
  def check_remote_status(site_url) do
    status_url = build_status_url(site_url)

    case make_get_request(status_url, @default_timeout) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Notifies a remote site to delete a connection.

  Called when a receiver deletes their connection - notifies the sender to also delete.

  ## Parameters

  - `connection` - The connection being deleted (must have site_url and auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, :deleted}` - Remote site deleted the connection
  - `{:ok, :not_found}` - Connection didn't exist on remote (already deleted)
  - `{:ok, :offline}` - Remote site is offline (will self-heal later)
  - `{:error, reason}` - Failed to notify
  """
  @spec notify_delete(connection_ref(), keyword()) ::
          {:ok, :deleted | :not_found | :offline} | {:error, term()}
  def notify_delete(connection, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      do_notify_delete(site_url, auth_token_hash, timeout)
    end
  end

  defp do_notify_delete(site_url, auth_token_hash, timeout) do
    api_url = build_delete_url(site_url)
    our_url = get_our_site_url()

    body = %{
      "sender_url" => our_url,
      "auth_token_hash" => auth_token_hash
    }

    Logger.info("Sync: Notifying remote site to delete connection", %{
      remote_url: site_url,
      api_url: api_url
    })

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: status}} when status in [200, 204] ->
        Logger.info("Sync: Remote site deleted connection successfully")
        {:ok, :deleted}

      {:ok, %{status: 404}} ->
        Logger.info("Sync: Connection not found on remote site (already deleted)")
        {:ok, :not_found}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "Sync: Remote site returned unexpected status #{status}: " <>
            truncate_body(resp_body)
        )

        {:error, {:unexpected_status, status}}

      {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
        Logger.info("Sync: Remote site offline, connection will self-heal")
        {:ok, :offline}

      {:error, reason} ->
        Logger.error("Sync: Failed to notify delete: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Notifies a remote site of a status change (suspend, reactivate, revoke).

  Called when a sender changes their connection status - the receiver should mirror it.

  ## Parameters

  - `connection` - The connection with updated status
  - `new_status` - The new status ("active", "suspended", "revoked")
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, :updated}` - Remote site updated the status
  - `{:ok, :skipped}` - A `"receiver"` connection: nothing is sent
  - `{:ok, :not_found}` - Connection not found on remote
  - `{:ok, :offline}` - Remote site is offline
  - `{:error, reason}` - Failed to notify
  """
  @spec notify_status_change(connection_ref(), String.t(), keyword()) ::
          {:ok, :updated | :skipped | :not_found | :offline} | {:error, term()}
  def notify_status_change(connection, new_status, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    cond do
      # Only the sender reports a status: the receiver mirrors it, and a
      # sender takes no status from its receiver (update-status refuses it).
      Map.get(connection, :direction) == "receiver" ->
        {:ok, :skipped}

      is_nil(site_url) or is_nil(auth_token_hash) ->
        {:error, :missing_connection_info}

      true ->
        do_notify_status_change(site_url, auth_token_hash, new_status, timeout)
    end
  end

  defp do_notify_status_change(site_url, auth_token_hash, new_status, timeout) do
    api_url = build_status_change_url(site_url)
    our_url = get_our_site_url()

    body = %{
      "sender_url" => our_url,
      "auth_token_hash" => auth_token_hash,
      "status" => new_status
    }

    Logger.info("Sync: Notifying remote site of status change", %{
      remote_url: site_url,
      new_status: new_status
    })

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: status}} when status in [200, 204] ->
        Logger.info("Sync: Remote site updated status successfully")
        {:ok, :updated}

      {:ok, %{status: 404}} ->
        Logger.info("Sync: Connection not found on remote site")
        {:ok, :not_found}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "Sync: Remote site returned unexpected status #{status}: " <>
            truncate_body(resp_body)
        )

        {:error, {:unexpected_status, status}}

      {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
        Logger.info("Sync: Remote site offline")
        {:ok, :offline}

      {:error, reason} ->
        Logger.error("Sync: Failed to notify status change: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Queries the sender for the current connection status.

  Called by receiver to sync their status with the sender's status.

  ## Parameters

  - `connection` - The receiver connection (must have site_url and auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, status}` - Current status from sender ("active", "suspended", "revoked")
  - `{:ok, :offline}` - Sender is offline
  - `{:ok, :not_found}` - Connection not found on sender
  - `{:error, reason}` - Failed to query
  """
  @spec query_sender_status(connection_ref(), keyword()) ::
          {:ok, String.t() | :offline | :not_found} | {:error, term()}
  def query_sender_status(connection, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_query_sender_status(site_url, auth_token_hash, opts)
    end
  end

  defp do_query_sender_status(site_url, auth_token_hash, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    api_url = build_get_status_url(site_url)

    body = %{
      "receiver_url" => get_our_site_url(),
      "auth_token_hash" => auth_token_hash
    }

    Logger.debug("Sync: Querying sender for connection status", %{sender_url: site_url})

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_status_response(resp_body)

      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      result ->
        handle_standard_http_result(result)
    end
  end

  defp parse_status_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "status" => status}} when is_binary(status) -> {:ok, status}
      {:ok, %{"success" => false}} -> {:ok, :not_found}
      _ -> {:error, :invalid_response}
    end
  end

  @doc """
  Verifies a connection still exists on the remote site.

  Called by sender to check if receiver still has the connection.
  If not, the sender should delete their own connection.

  ## Returns

  - `{:ok, :exists}` - Connection exists on remote
  - `{:ok, :not_found}` - Connection was deleted on remote
  - `{:ok, :offline}` - Remote site is offline
  - `{:error, reason}` - Failed to verify
  """
  @spec verify_connection(connection_ref(), keyword()) ::
          {:ok, :exists | :not_found | :offline} | {:error, term()}
  def verify_connection(connection, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      do_verify_connection(site_url, auth_token_hash, timeout)
    end
  end

  defp do_verify_connection(site_url, auth_token_hash, timeout) do
    api_url = build_verify_url(site_url)
    our_url = get_our_site_url()

    body = %{
      "sender_url" => our_url,
      "auth_token_hash" => auth_token_hash
    }

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200}} ->
        {:ok, :exists}

      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: _status}} ->
        # Assume exists if we get any other response
        {:ok, :exists}

      {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
        {:ok, :offline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches the list of available tables from the sender.

  Called by receiver to get a list of tables that can be synced.

  ## Parameters

  - `connection` - The receiver connection (must have site_url and auth_token/auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, tables}` - List of table info maps with :name, :row_count, :size_bytes
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch
  """
  @spec fetch_sender_tables(connection_ref(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_sender_tables(connection, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_sender_tables(site_url, auth_token_hash, opts)
    end
  end

  defp do_fetch_sender_tables(site_url, auth_token_hash, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    api_url = build_list_tables_url(site_url)
    body = put_password(%{"auth_token_hash" => auth_token_hash}, opts)

    Logger.debug("Sync: Fetching tables from sender", %{sender_url: site_url})

    case make_limited_request(api_url, body, timeout, opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_tables_response(resp_body)

      result ->
        handle_api_http_result(result)
    end
  end

  defp parse_tables_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "tables" => tables}} when is_list(tables) ->
        convert_tables_to_structs(tables)

      {:ok, %{"success" => false}} ->
        {:error, :unexpected_response}

      _ ->
        {:error, :invalid_response}
    end
  end

  # The list is the sender's: an entry that is not an object with a name is
  # a malformed answer, and a field of the wrong type reads as absent.
  defp convert_tables_to_structs(tables) do
    if Enum.all?(tables, &match?(%{"name" => name} when is_binary(name), &1)) do
      {:ok,
       Enum.map(tables, fn t ->
         %{
           name: t["name"],
           row_count: integer_or(t["row_count"], 0),
           size_bytes: integer_or(t["size_bytes"], 0),
           checksum: if(is_binary(t["checksum"]), do: t["checksum"]),
           depends_on: string_list(t["depends_on"])
         }
       end)}
    else
      {:error, :invalid_response}
    end
  end

  defp integer_or(value, _default) when is_integer(value), do: value
  defp integer_or(_value, default), do: default

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  @doc """
  Pulls data for a specific table from the sender.

  Called by receiver to fetch table data during sync.

  ## Parameters

  - `connection` - The receiver connection
  - `table_name` - Name of the table to pull
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 60_000ms for large data)
    - `:conflict_strategy` - How to handle existing records ("skip", "overwrite", "merge")
    - `:ids` - Only the rows with these key values (1 to 1000)
    - `:id_range` - `{start, end}`: only the rows of an integer key range;
      one bound may be nil, not both
    - `:actor_uuid` - The user who started the pull; recorded on the
      transfer (`initiated_by_uuid`) and its activity row
    - `:password` - The sender connection's download password, when it has one
    - `:on_rate_limited` - A function of one argument, called with the
      seconds before each wait when the sender answers 429 (over the
      connection's requests per minute). `fetch_sender_tables/2`,
      `fetch_table_schema/3` and `fetch_table_records/3` take it too

  A request the sender refuses with 429 is sent again after its
  `Retry-After` (clamped, within a total budget: `PhoenixKitSync.RateLimit`);
  past the budget the pull fails with `:rate_limited`.

  A table larger than the sender's `max_records_per_request` comes in pages:
  the sender's answer says where the next one starts, and the pull follows
  until the table ends. Each timeout is per page.

  A filter goes to the sender with the request; an answer that does not
  carry `"filtered": true` (a sender from before filters) is not imported.

  ## Returns

  - `{:ok, result}` - Map with `:imported`, `:skipped`, `:errors`, plus
    `:unknown_columns` when some records carried columns the local table
    lacks (those records count as errors), and `truncated: true` when the
    sender stopped at its max_records_per_request limit and gave no cursor
    to continue from (a sender from before cursors, a key type without one,
    or one that did not honour its own cursor): the rows that came are
    imported, but the transfer is recorded as failed. `:unsupported_key_type`
    names the key type when the sender said that is why
  - `{:error, :offline}` - Sender is offline
  - `{:error, :invalid_table_name}` - The name is not a plain identifier;
    nothing is recorded or requested
  - `{:error, :invalid_column_name}` - The sender's data has a key that is
    not a plain identifier; no row of the table is written
  - `{:error, :invalid_response}` - The sender's answer could not be read
  - `{:error, :invalid_filter}` - An empty, oversized or malformed filter
    (refused before the request), or one the sender refused
  - `{:error, :unsupported_key_type}` - The sender's key type takes no filter
  - `{:error, :sender_ignores_filters}` - The sender ignored the filter;
    nothing is imported
  - `{:error, :table_missing_locally}` - The table does not exist on this
    site; nothing is requested from the sender
  - `{:error, :no_primary_key}` - The local table has no primary key; it is
    not pulled, since repeat pulls would duplicate rows
  - `{:error, :import_failed}` - Handling the response raised or exited; the
    transfer is marked failed and the details are in the log
  - `{:error, reason}` - Failed to pull
  """
  @spec pull_table_data(connection_ref(), String.t(), keyword()) ::
          {:ok, pull_result()} | {:error, term()}
  def pull_table_data(connection, table_name, opts \\ []) do
    with :ok <- check_table_name(table_name),
         {:ok, filter_body} <- PullFilter.body(opts),
         {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      connection_uuid = Map.get(connection, :uuid)

      do_pull_table_data(
        site_url,
        auth_token_hash,
        connection_uuid,
        table_name,
        Keyword.put(opts, :filter_body, filter_body)
      )
    end
  end

  @doc """
  Same as pull_table_data but accepts and returns a uuid_remap for FK remapping across tables.
  Returns {:ok, import_result, updated_remap} or {:error, reason, unchanged_remap},
  with the same error reasons as `pull_table_data/3`.
  """
  @spec pull_table_data_with_remap(connection_ref(), String.t(), uuid_remap(), keyword()) ::
          {:ok, pull_result(), uuid_remap()} | {:error, term(), uuid_remap()}
  def pull_table_data_with_remap(connection, table_name, uuid_remap, opts \\ []) do
    with :ok <- check_table_name(table_name),
         {:ok, filter_body} <- PullFilter.body(opts) do
      pull_checked_table_with_remap(
        connection,
        table_name,
        uuid_remap,
        Keyword.put(opts, :filter_body, filter_body)
      )
    else
      {:error, reason} -> {:error, reason, uuid_remap}
    end
  end

  # The table name comes from the sender's table list. It goes into the
  # transfer row, the log and the INSERT, so anything but a plain identifier
  # (at most 63 bytes, like every Postgres name) stops here, unechoed.
  defp check_table_name(table_name) do
    cond do
      not SchemaInspector.valid_identifier?(table_name) ->
        Logger.warning("Sync: refusing to pull a table whose name is not a valid identifier")
        {:error, :invalid_table_name}

      SchemaInspector.excluded_table?(table_name) ->
        Logger.warning("Sync: refusing to pull #{table_name}, a table that is never synced")
        {:error, :table_excluded}

      true ->
        :ok
    end
  end

  defp pull_checked_table_with_remap(connection, table_name, uuid_remap, opts) do
    case extract_connection_info(connection) do
      {:ok, site_url, auth_token_hash} ->
        connection_uuid = Map.get(connection, :uuid)

        do_pull_table_data_with_remap(
          site_url,
          auth_token_hash,
          connection_uuid,
          table_name,
          uuid_remap,
          opts
        )

      {:error, reason} ->
        {:error, reason, uuid_remap}
    end
  end

  defp do_pull_table_data(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         opts
       ) do
    import_page = fn data, conflict_strategy, target, remap ->
      {import_table_data(table_name, data, conflict_strategy, target), remap}
    end

    case run_pull(
           site_url,
           auth_token_hash,
           connection_uuid,
           table_name,
           %{},
           opts,
           import_page
         ) do
      {:ok, result, _remap} -> {:ok, result}
      {:error, reason, _remap} -> {:error, reason}
    end
  end

  defp do_pull_table_data_with_remap(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         uuid_remap,
         opts
       ) do
    import_page = fn data, conflict_strategy, target, remap ->
      import_table_data_with_remap(table_name, data, conflict_strategy, remap, target)
    end

    run_pull(
      site_url,
      auth_token_hash,
      connection_uuid,
      table_name,
      uuid_remap,
      opts,
      import_page
    )
  end

  # The most pages one pull follows. At the default page size that is far
  # more rows than any synced table holds; it is here so that a sender
  # handing out cursors forever cannot keep a pull running forever.
  @max_pull_pages 10_000

  # One pull of one table: a transfer row, then page after page until the
  # sender has no more. Returns `{:ok, result, remap}` or
  # `{:error, reason, remap}`.
  defp run_pull(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         uuid_remap,
         opts,
         import_page
       ) do
    conflict_strategy = Keyword.get(opts, :conflict_strategy, "skip")
    filter_body = Keyword.get(opts, :filter_body, %{})

    Logger.info("Sync: Pulling data for table #{table_name}", %{sender_url: site_url})

    {:ok, transfer} =
      create_pull_transfer(
        connection_uuid,
        table_name,
        site_url,
        conflict_strategy,
        Keyword.get(opts, :actor_uuid)
      )

    # "paged" tells the sender this receiver follows "next_after", so a
    # page that stops at its limit is not the end of the send.
    body =
      filter_body
      |> Map.merge(%{
        "auth_token_hash" => auth_token_hash,
        "table_name" => table_name,
        "conflict_strategy" => conflict_strategy,
        "paged" => true
      })
      |> put_password(opts)

    pull = %{
      api_url: build_pull_data_url(site_url),
      timeout: Keyword.get(opts, :timeout, 60_000),
      request_opts: Keyword.take(opts, [:on_rate_limited]),
      table_name: table_name,
      transfer: transfer,
      conflict_strategy: conflict_strategy,
      filtered?: filter_body != %{},
      body: body,
      import_page: import_page
    }

    progress = %{
      remap: uuid_remap,
      after: nil,
      cursor: nil,
      page: 0,
      prev_first: nil,
      records: 0,
      result: %{imported: 0, skipped: 0, errors: 0}
    }

    guard_transfer(transfer, table_name, &{:error, &1, uuid_remap}, fn ->
      case check_local_table(transfer, table_name) do
        {:ok, target} -> pull_pages(Map.put(pull, :target, target), progress)
        {:error, reason} -> {:error, reason, uuid_remap}
      end
    end)
  end

  # The sender connection's download password, when the caller has one. It
  # goes in the request body the sender reads it from and nowhere else: not
  # into a log line, a transfer row or activity metadata.
  defp put_password(body, opts) do
    case Keyword.get(opts, :password) do
      password when is_binary(password) and password != "" ->
        Map.put(body, "password", password)

      _ ->
        body
    end
  end

  # Why the sender refused a table request under this connection (403 with
  # an error_code): the atom for a code this module knows, else nil.
  defp connection_refusal(%{status: 403, body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error_code" => code}} when is_binary(code) -> @connection_refusals[code]
      _ -> nil
    end
  end

  defp connection_refusal(_response), do: nil

  defp create_pull_transfer(
         connection_uuid,
         table_name,
         site_url,
         conflict_strategy,
         actor_uuid
       ) do
    Transfers.create_transfer(
      %{
        direction: "receive",
        connection_uuid: connection_uuid,
        table_name: table_name,
        remote_site_url: site_url,
        conflict_strategy: conflict_strategy,
        status: "in_progress",
        started_at: UtilsDate.utc_now(),
        initiated_by_uuid: actor_uuid
      },
      actor_uuid: actor_uuid
    )
  end

  defp pull_pages(pull, progress) do
    body =
      case progress do
        %{after: nil} ->
          pull.body

        %{after: after_values, cursor: nil} ->
          Map.put(pull.body, "after", after_values)

        %{after: after_values, cursor: cursor} ->
          Map.merge(pull.body, %{"after" => after_values, "cursor" => cursor})
      end

    case fetch_pull_page(pull, body) do
      {:ok, response, data} ->
        handle_pull_page(pull, progress, response, data)

      {:error, reason, _message} ->
        Transfers.fail_transfer(pull.transfer, Atom.to_string(reason), pull_stats(progress))
        {:error, reason, progress.remap}
    end
  end

  defp handle_pull_page(pull, progress, response, data) do
    cond do
      # Asked for some rows, got an answer without "filtered": true. A
      # sender that predates filters ignores them and sends the whole table,
      # so the answer is not imported at all.
      pull.filtered? and response["filtered"] != true ->
        {:error, reason} = fail_ignored_filter(pull.transfer)
        {:error, reason, progress.remap}

      # Asked for the rows after a key, got the page that was already
      # imported: this sender does not page. What came stays, and the table
      # is reported as cut.
      progress.page > 0 and data != [] and List.first(data) == progress.prev_first ->
        Logger.warning("Sync: the sender repeated a page of #{pull.table_name}; pull stopped")
        {:ok, finish_pull_transfer(pull.transfer, progress, {:truncated, nil}), progress.remap}

      true ->
        import_pull_page(pull, progress, response, data)
    end
  end

  defp import_pull_page(pull, progress, response, data) do
    case check_record_keys(pull.transfer, data) do
      :ok ->
        {page_result, remap} =
          pull.import_page.(data, pull.conflict_strategy, pull.target, progress.remap)

        progress = %{
          progress
          | remap: remap,
            records: progress.records + length(data),
            result: merge_import_results(progress.result, page_result)
        }

        continue_pull(pull, progress, response, List.first(data))

      {:error, reason} ->
        {:error, reason, progress.remap}
    end
  end

  # A sender that stopped at its max_records_per_request says "truncated".
  # One that pages also says where to continue ("next_after"); one from
  # before cursors, or a key with no cursor, does not, and the pull ends
  # there, cut.
  defp continue_pull(pull, progress, response, first_record) do
    next_after = response["next_after"]

    cond do
      response["truncated"] != true ->
        {:ok, finish_pull_transfer(pull.transfer, progress, false), progress.remap}

      is_map(next_after) and map_size(next_after) > 0 and next_after != progress.after and
          progress.page + 1 < @max_pull_pages ->
        cursor = if is_binary(response["cursor"]), do: response["cursor"]

        pull_pages(pull, %{
          progress
          | after: next_after,
            cursor: cursor,
            page: progress.page + 1,
            prev_first: first_record
        })

      true ->
        cut = {:truncated, unsupported_key_type(response)}
        {:ok, finish_pull_transfer(pull.transfer, progress, cut), progress.remap}
    end
  end

  # The key type a sender names when it cut the answer because that type
  # has no cursor. It is the peer's text and ends up on the admin's page:
  # only a short printable name is kept.
  defp unsupported_key_type(%{"unsupported_key_type" => type}) when is_binary(type) do
    if byte_size(type) in 1..200 and String.printable?(type), do: type
  end

  defp unsupported_key_type(_response), do: nil

  defp merge_import_results(total, page) do
    merged = %{
      total
      | imported: total.imported + page.imported,
        skipped: total.skipped + page.skipped,
        errors: total.errors + page.errors
    }

    case Enum.uniq(Map.get(total, :unknown_columns, []) ++ Map.get(page, :unknown_columns, [])) do
      [] -> merged
      columns -> Map.put(merged, :unknown_columns, Enum.sort(columns))
    end
  end

  defp pull_stats(progress) do
    %{
      records_transferred: progress.records,
      records_created: progress.result.imported,
      records_skipped: progress.result.skipped,
      records_failed: progress.result.errors
    }
  end

  # One request of a pull: `{:ok, response, data}` for a page of rows, or
  # `{:error, reason, message}` with the text the transfer row records.
  defp fetch_pull_page(pull, body) do
    case make_limited_request(pull.api_url, body, pull.timeout, pull.request_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        read_pull_page(Jason.decode(resp_body))

      {:ok, %{status: status, body: resp_body}} when status in [400, 403] ->
        refused_pull_page(status, resp_body, pull.filtered?)

      {:ok, %{status: 401}} ->
        Logger.error("Sync: Pull failed - unauthorized (401)")
        {:error, :unauthorized, "Unauthorized"}

      {:ok, %{status: 404}} ->
        Logger.error("Sync: Pull failed - table not found (404)")
        {:error, :table_not_found, "Table not found"}

      {:ok, %{status: status}} ->
        Logger.error("Sync: Pull failed - HTTP error #{status}")
        {:error, :unexpected_response, "HTTP error #{status}"}

      {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
        Logger.error("Sync: Pull failed - sender offline (#{reason})")
        {:error, :offline, "Sender offline"}

      {:error, reason} ->
        Logger.error("Sync: Pull failed - #{inspect(reason)}")
        classified = transport_reason(reason)
        {:error, classified, Atom.to_string(classified)}
    end
  end

  defp read_pull_page({:ok, %{"success" => true, "data" => data} = response}) when is_list(data),
    do: {:ok, response, data}

  defp read_pull_page({:ok, %{"success" => false, "error" => error}}) when is_binary(error) do
    Logger.error("Sync: Pull failed - remote site refused the pull")
    {:error, :pull_failed, "pull_failed"}
  end

  # A remote error that is not a string (a map, a list) is not shown or
  # stored: it is the sender's payload, and interpolating it would raise.
  defp read_pull_page({:ok, %{"success" => false}}) do
    Logger.error("Sync: Pull failed - remote sent an error that is not a string")
    {:error, :invalid_response, "Invalid response from remote site"}
  end

  defp read_pull_page(_other) do
    Logger.error("Sync: Pull failed - invalid response format")
    {:error, :invalid_response, "Invalid response from remote site"}
  end

  # What a sender refuses a pull with, by its "error_code". A sender that
  # knows filters answers one it cannot apply (a range on a non-integer key,
  # a composite key) with 400; one that enforces a connection's limits
  # answers 403 with the limit that stopped it.
  @filter_refusals %{
    "unsupported_key_type" => :unsupported_key_type,
    "filter_needs_single_key" => :filter_needs_single_key,
    "invalid_filter" => :invalid_filter
  }

  defp refused_pull_page(status, resp_body, filtered?) do
    code =
      case Jason.decode(resp_body) do
        {:ok, %{"error_code" => code}} when is_binary(code) -> code
        _ -> nil
      end

    cond do
      reason = @pull_refusals[code] ->
        Logger.error("Sync: Pull refused by the sender (#{reason})")
        {:error, reason, "The sender refused the pull (#{reason})"}

      status == 400 and filtered? ->
        # "invalid_filter", or a sender that predates error_code.
        reason = Map.get(@filter_refusals, code, :invalid_filter)
        Logger.error("Sync: Pull failed - the sender refused the record filter (#{reason})")
        {:error, reason, "The sender refused the record filter"}

      true ->
        Logger.error("Sync: Pull failed - HTTP error #{status}")
        {:error, :unexpected_response, "HTTP error #{status}"}
    end
  end

  defp fail_ignored_filter(transfer) do
    Logger.error("Sync: Pull refused - the sender ignored the record filter")
    Transfers.fail_transfer(transfer, "sender_ignores_filters")
    {:error, :sender_ignores_filters}
  end

  # The rows of a cut answer are imported, and the uuid remap they built
  # holds for the tables after it, but the table is not whole: the transfer
  # fails with the reason and the counts, and the result carries
  # `truncated: true` for the caller to show.
  defp finish_pull_transfer(transfer, progress, false) do
    Transfers.complete_transfer(transfer, pull_stats(progress))
    progress.result
  end

  defp finish_pull_transfer(transfer, progress, {:truncated, nil}) do
    Logger.warning("Sync: Pull stopped at the sender's max_records_per_request limit")

    Transfers.fail_transfer(
      transfer,
      "truncated",
      pull_stats(progress)
    )

    Map.put(progress.result, :truncated, true)
  end

  # The sender is current; it is the table's key it cannot continue from.
  # Updating the source site would not help, so the reason names the type.
  defp finish_pull_transfer(transfer, progress, {:truncated, key_type}) do
    Logger.warning("Sync: Pull stopped - the sender has no cursor for a #{key_type} key")

    Transfers.fail_transfer(
      transfer,
      "truncated_key_type:" <> key_type,
      pull_stats(progress)
    )

    Map.merge(progress.result, %{truncated: true, unsupported_key_type: key_type})
  end

  # Checked before the request, so a table that cannot be imported here does
  # not spend the sender's download and record limits. A table missing on
  # this site has to be created first (Precise Transfer > Create Table).
  # Without a primary key there is nothing to detect a row that is already
  # here: every pull would insert the same rows again, so such a table is
  # not imported at all.
  defp check_local_table(transfer, table_name) do
    case SchemaInspector.get_schema(table_name) do
      {:ok, %{primary_key: []}} ->
        reject_local_table(transfer, :no_primary_key, "No primary key on #{table_name}")

      {:ok, %{primary_key: pk_cols, columns: columns}} ->
        {:ok,
         %{
           pk_cols: pk_cols,
           columns: MapSet.new(columns, & &1.name),
           column_types: Map.new(columns, &{&1.name, column_type(&1)}),
           not_null: for(col <- columns, col.nullable == false, into: MapSet.new(), do: col.name)
         }}

      {:error, :not_found} ->
        reject_local_table(
          transfer,
          :table_missing_locally,
          "Table #{table_name} does not exist here"
        )

      # A failed lookup is not a missing table; guard_transfer turns this
      # into :import_failed.
      {:error, reason} ->
        raise "schema lookup for #{table_name} failed: #{inspect(reason)}"
    end
  end

  # Record keys become column names in the INSERT. A key that is not a
  # plain identifier means a broken or hostile sender, so the whole table is
  # refused before any row is written.
  defp check_record_keys(transfer, data) when is_list(data) do
    valid? =
      Enum.all?(data, fn
        record when is_map(record) ->
          Enum.all?(Map.keys(record), &SchemaInspector.valid_identifier?(to_string(&1)))

        _ ->
          true
      end)

    if valid? do
      :ok
    else
      Logger.warning("Sync: sender data has a column name that is not a valid identifier")
      Transfers.fail_transfer(transfer, "invalid_column_name")
      {:error, :invalid_column_name}
    end
  end

  defp check_record_keys(_transfer, _data), do: :ok

  defp reject_local_table(transfer, reason, why) do
    Logger.warning("Sync: #{why}; not pulling it")
    Transfers.fail_transfer(transfer, Atom.to_string(reason))
    {:error, reason}
  end

  # Everything after the transfer row exists runs under this: a response
  # handler or an import that raises or exits fails the transfer instead of
  # leaving it in_progress, and the caller gets `wrap_error.(:import_failed)`
  # instead of a crash.
  defp guard_transfer(transfer, table_name, wrap_error, fun) do
    fun.()
  catch
    kind, reason ->
      wrap_error.(fail_import(transfer, table_name, kind, reason, __STACKTRACE__))
  end

  # Exception messages can quote row values, so the log names only the
  # exception type and the transfer stores a classified reason. Rows inserted before the failure stay (each INSERT is
  # its own statement), and the transfer records no counts for them: those
  # counts lived in the import loop that raised.
  defp fail_import(transfer, table_name, kind, reason, _stacktrace) do
    Logger.error("Sync: Import of #{table_name} failed (#{error_kind(kind, reason)})")
    Transfers.fail_transfer(transfer, "import_failed")
    :import_failed
  end

  defp error_kind(:error, reason) when is_exception(reason), do: inspect(reason.__struct__)
  defp error_kind(kind, _reason), do: Atom.to_string(kind)

  @doc """
  Fetch table schema from a sender site via HTTP API.

  Returns:
  - `{:ok, schema}` - Map with :columns list
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch schema
  """
  @spec fetch_table_schema(connection_ref(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_table_schema(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_schema(site_url, auth_token_hash, table_name, opts)
    end
  end

  defp do_fetch_table_schema(site_url, auth_token_hash, table_name, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_schema_url(site_url)

    body =
      put_password(%{"auth_token_hash" => auth_token_hash, "table_name" => table_name}, opts)

    case make_limited_request(api_url, body, timeout, opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_schema_response(resp_body)

      result ->
        handle_table_http_result(result)
    end
  end

  defp parse_schema_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "schema" => schema}} when is_map(schema) ->
        # Older senders describe columns as column_name/data_type/is_nullable
        # and send no primary key; normalise so the page and create_table/3
        # read one shape.
        if PhoenixKitSync.PeerData.valid_schema?(schema),
          do: {:ok, Map.merge(schema, SchemaInspector.normalize_schema_def(schema))},
          else: {:error, :invalid_response}

      {:ok, %{"success" => false}} ->
        {:error, :unexpected_response}

      _ ->
        {:error, :invalid_response}
    end
  end

  @doc """
  Fetch table records from a sender site via HTTP API for preview.

  Options:
  - `:limit` - Maximum number of records to fetch (default: 10)
  - `:offset` - Offset for pagination (default: 0)
  - `:ids` - List of specific IDs to fetch
  - `:id_range` - Tuple of {start_id, end_id}

  Returns:
  - `{:ok, records}` - List of record maps
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch records
  """
  @spec fetch_table_records(connection_ref(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_table_records(connection, table_name, opts \\ []) do
    # The same filter rules as the pull, so a preview and a transfer of the
    # same input agree (an empty ID list is refused by both).
    with {:ok, filter_body} <- PullFilter.body(Keyword.take(opts, [:ids, :id_range])),
         {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_records(site_url, auth_token_hash, table_name, filter_body, opts)
    end
  end

  defp do_fetch_table_records(site_url, auth_token_hash, table_name, filter_body, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_records_url(site_url)

    body =
      filter_body
      |> Map.merge(build_records_request_body(auth_token_hash, table_name, opts))
      |> put_password(opts)

    case make_limited_request(api_url, body, timeout, opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_records_response(resp_body)

      result ->
        handle_table_http_result(result)
    end
  end

  defp build_records_request_body(auth_token_hash, table_name, opts) do
    %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "limit" => Keyword.get(opts, :limit, 10),
      "offset" => Keyword.get(opts, :offset, 0)
    }
  end

  defp parse_records_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "records" => records}} when is_list(records) ->
        if Enum.all?(records, &is_map/1), do: {:ok, records}, else: {:error, :invalid_response}

      {:ok, %{"success" => false}} ->
        {:error, :unexpected_response}

      _ ->
        {:error, :invalid_response}
    end
  end

  # --- Connection Info Helpers ---

  defp extract_connection_info(connection) do
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      {:ok, site_url, auth_token_hash}
    end
  end

  # --- HTTP Response Handlers ---

  defp handle_standard_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_standard_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:ok, :offline}
  end

  defp handle_standard_http_result({:error, reason}), do: {:error, transport_reason(reason)}

  defp handle_api_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_api_http_result({:ok, %{status: 404}}), do: {:error, :not_found}

  defp handle_api_http_result({:ok, response}),
    do: {:error, connection_refusal(response) || :unexpected_response}

  defp handle_api_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_api_http_result({:error, reason}), do: {:error, transport_reason(reason)}

  defp handle_table_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_table_http_result({:ok, %{status: 404}}), do: {:error, :table_not_found}

  # A filter the sender cannot apply (a range on a non-integer key, an ID
  # list on a composite key) comes back as 400 with an error_code.
  defp handle_table_http_result({:ok, %{status: 400, body: body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error_code" => "invalid_filter"}} -> {:error, :invalid_filter}
      {:ok, %{"error_code" => "unsupported_key_type"}} -> {:error, :unsupported_key_type}
      {:ok, %{"error_code" => "filter_needs_single_key"}} -> {:error, :filter_needs_single_key}
      _ -> {:error, :unexpected_response}
    end
  end

  defp handle_table_http_result({:ok, response}),
    do: {:error, connection_refusal(response) || :unexpected_response}

  defp handle_table_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_table_http_result({:error, reason}), do: {:error, transport_reason(reason)}

  defp transport_reason(reason)
       when reason in [:response_too_large, :invalid_response, :rate_limited],
       do: reason

  defp transport_reason(%{reason: reason}) when reason in [:econnrefused, :timeout, :nxdomain],
    do: :offline

  defp transport_reason(_reason), do: :unexpected_response

  # --- Private Functions ---

  defp build_api_url(site_url), do: build_sync_url(site_url, "register-connection")
  defp build_status_url(site_url), do: build_sync_url(site_url, "status")
  defp build_delete_url(site_url), do: build_sync_url(site_url, "delete-connection")
  defp build_verify_url(site_url), do: build_sync_url(site_url, "verify-connection")
  defp build_status_change_url(site_url), do: build_sync_url(site_url, "update-status")
  defp build_get_status_url(site_url), do: build_sync_url(site_url, "get-connection-status")
  defp build_list_tables_url(site_url), do: build_sync_url(site_url, "list-tables")
  defp build_pull_data_url(site_url), do: build_sync_url(site_url, "pull-data")
  defp build_schema_url(site_url), do: build_sync_url(site_url, "table-schema")
  defp build_records_url(site_url), do: build_sync_url(site_url, "table-records")

  defp build_sync_url(site_url, endpoint) do
    base_url = String.trim_trailing(site_url, "/")
    "#{base_url}#{remote_url_prefix()}/sync/api/#{endpoint}"
  end

  @doc """
  Returns the URL prefix the notifier prepends to remote sync API paths.

  The remote site mounts its sync routes under `PhoenixKit.Config.get_url_prefix/0`
  (via `PhoenixKitSync.Routes.generate/1`), so by default we mirror the *local*
  site's configured prefix — correct whenever both deployments share the same
  routing config, which is the common case. (Previously this was hardcoded to
  `/phoenix_kit`, which 404'd against any remote mounted under a different
  prefix — see https://github.com/BeamLabEU/phoenix_kit_sync/issues/8.)

  Deployments whose remote uses a different prefix than the local site can
  override it globally:

      config :phoenix_kit_sync, remote_url_prefix: "/custom"

  The result is normalized: a leading slash is ensured, trailing slashes are
  stripped, and an empty or root prefix (`""` or `"/"`) yields `""` so paths
  resolve to `<site_url>/sync/api/...`.
  """
  @spec remote_url_prefix() :: String.t()
  def remote_url_prefix do
    case Application.get_env(:phoenix_kit_sync, :remote_url_prefix) do
      nil -> local_url_prefix()
      configured -> configured
    end
    |> normalize_prefix()
  end

  # Mirror the local site's configured prefix. Falls back to PhoenixKit's own
  # default if Config isn't available, matching integration.ex's behaviour.
  defp local_url_prefix do
    PhoenixKit.Config.get_url_prefix()
  rescue
    _ -> "/phoenix_kit"
  end

  defp normalize_prefix(prefix) when is_binary(prefix) do
    case prefix |> String.trim() |> String.trim_trailing("/") do
      "" -> ""
      "/" <> _ = normalized -> normalized
      normalized -> "/" <> normalized
    end
  end

  defp normalize_prefix(_), do: ""

  defp build_request_body(conn_name, our_url, raw_token, password) do
    body = %{
      "sender_url" => our_url,
      "connection_name" => conn_name,
      "auth_token" => raw_token
    }

    if password do
      Map.put(body, "password", password)
    else
      body
    end
  end

  @doc """
  Resolves this site's own URL from Settings, config, or dynamic detection.
  Used to identify ourselves when communicating with remote sites.
  """
  @spec get_our_site_url() :: String.t()
  def get_our_site_url do
    case Settings.get_setting("site_url", nil) do
      nil ->
        url = get_our_site_url_fallback()

        Logger.warning(
          "[Sync.Notifier] site_url not set in Settings, using fallback " <>
            "| resolved_url=#{url}"
        )

        url

      "" ->
        url = get_our_site_url_fallback()

        Logger.warning(
          "[Sync.Notifier] site_url is empty in Settings, using fallback " <>
            "| resolved_url=#{url}"
        )

        url

      url ->
        Logger.debug("[Sync.Notifier] Using site_url from Settings | url=#{url}")
        url
    end
  end

  defp get_our_site_url_fallback do
    case Application.get_env(:phoenix_kit, :public_url) do
      nil ->
        url = PhoenixKit.Config.get_dynamic_base_url()
        Logger.debug("[Sync.Notifier] Fallback: dynamic base URL | url=#{url}")
        url

      url ->
        Logger.debug("[Sync.Notifier] Fallback: :public_url config | url=#{url}")
        url
    end
  end

  defp make_http_request(url, body, timeout) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    case Jason.encode(body) do
      {:ok, json_body} ->
        :post
        |> Finch.build(url, headers, json_body)
        |> request_capped(timeout, max_response_bytes(url))

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp make_get_request(url, timeout) do
    headers = [
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    :get
    |> Finch.build(url, headers)
    |> request_capped(timeout, max_response_bytes(url))
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  # A request the sender may answer with 429 because this connection is
  # over its requests per minute (the four table endpoints). The sender's
  # Retry-After is waited out and the same request sent again, each wait
  # clamped and all of them within a budget (`PhoenixKitSync.RateLimit`);
  # past the budget the request fails with `:rate_limited`. Before each wait
  # `opts[:on_rate_limited]`, when given, is called with the seconds, so a
  # page can say why nothing is moving.
  defp make_limited_request(url, body, timeout, opts, waited \\ 0) do
    case make_http_request(url, body, timeout) do
      {:ok, %{status: 429} = response} ->
        case RateLimit.next_wait(retry_after(response), waited) do
          {:wait, seconds} ->
            Logger.info("Sync: the sender is rate limiting this connection; waiting #{seconds} s")
            notify_rate_limited(opts, seconds)
            Process.sleep(seconds * 1000)
            make_limited_request(url, body, timeout, opts, waited + seconds)

          :give_up ->
            Logger.warning("Sync: the sender kept rate limiting this connection; giving up")
            {:error, :rate_limited}
        end

      result ->
        result
    end
  end

  defp retry_after(%{headers: headers}) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "retry-after", do: value
    end)
  end

  defp notify_rate_limited(opts, seconds) do
    case Keyword.get(opts, :on_rate_limited) do
      fun when is_function(fun, 1) -> fun.(seconds)
      _none -> :ok
    end
  end

  # The remote site decides how much it answers, and an answer is held in
  # memory whole. Every request reads at most `max_bytes` of body and then
  # drops the connection with `{:error, :response_too_large}`. Three sizes:
  # a page of records is allowed far more than the rest, and a host that
  # moves bigger pages raises it with
  # `config :phoenix_kit_sync, max_response_bytes:` (bytes); a table list or
  # a table's schema grows with the database (some 300 bytes a table or a
  # column), so it gets room for tens of thousands of them and no more
  # (never more than the host allows a page of records); and every other
  # answer is a few fields.
  @control_max_response_bytes 1_048_576
  @schema_max_response_bytes 16_777_216
  @default_max_response_bytes 268_435_456
  @record_endpoints ["/pull-data", "/table-records"]
  @schema_endpoints ["/list-tables", "/table-schema"]

  defp max_response_bytes(url) do
    records_max =
      Application.get_env(:phoenix_kit_sync, :max_response_bytes, @default_max_response_bytes)

    cond do
      Enum.any?(@record_endpoints, &String.ends_with?(url, &1)) ->
        records_max

      Enum.any?(@schema_endpoints, &String.ends_with?(url, &1)) ->
        min(@schema_max_response_bytes, records_max)

      true ->
        @control_max_response_bytes
    end
  end

  defp request_capped(request, timeout, max_bytes) do
    acc = %{status: nil, headers: [], size: 0, chunks: []}

    collect = fn
      {:status, status}, acc ->
        {:cont, %{acc | status: status}}

      {:headers, headers}, acc ->
        {:cont, %{acc | headers: acc.headers ++ headers}}

      {:data, chunk}, acc ->
        size = acc.size + byte_size(chunk)

        if size > max_bytes,
          do: {:halt, %{acc | size: size, chunks: :too_large}},
          else: {:cont, %{acc | size: size, chunks: [chunk | acc.chunks]}}

      _trailers_or_other, acc ->
        {:cont, acc}
    end

    case Finch.stream_while(request, get_finch_name(), acc, collect,
           receive_timeout: timeout,
           request_timeout: timeout,
           pool_timeout: @connect_timeout
         ) do
      {:ok, %{chunks: :too_large}} ->
        Logger.warning("Sync: dropped a response larger than #{max_bytes} bytes")
        {:error, :response_too_large}

      {:ok, %{status: status, headers: headers, chunks: chunks}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, reason, _acc} ->
        {:error, reason}
    end
  end

  defp get_finch_name do
    # Use Swoosh.Finch if available (added by PhoenixKit install)
    # Fall back to PhoenixKit.Finch
    if Process.whereis(Swoosh.Finch) do
      Swoosh.Finch
    else
      PhoenixKit.Finch
    end
  end

  defp parse_response(%{status: 200, body: body}) do
    case Jason.decode(body) do
      {:ok, %{"success" => true} = data} ->
        parse_success_response(data)

      {:ok, %{"success" => false} = data} ->
        build_error_result(200, data["error"] || "Remote site rejected connection")

      _ ->
        build_error_result(200, "Invalid JSON response", "Invalid response from remote site")
    end
  end

  defp parse_response(%{status: 401, body: body}) do
    error_msg = extract_error(body, "Password required or invalid")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 401,
      error: error_msg
    }
  end

  defp parse_response(%{status: 403, body: body}) do
    error_msg = extract_error(body, "Incoming connections denied")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 403,
      error: error_msg
    }
  end

  defp parse_response(%{status: 409, body: body}) do
    error_msg = extract_error(body, "Connection already exists")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 409,
      error: error_msg
    }
  end

  defp parse_response(%{status: 503, body: body}) do
    error_msg = extract_error(body, "DB Sync module disabled on remote site")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 503,
      error: error_msg
    }
  end

  defp parse_response(%{status: status, body: body}) do
    error_msg = extract_error(body, "HTTP error #{status}")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: status,
      error: error_msg
    }
  end

  defp parse_success_response(data) do
    status =
      case data["connection_status"] do
        "active" -> :registered
        "pending" -> :pending
        _ -> :registered
      end

    %{
      success: true,
      status: status,
      message: data["message"] || "Connection registered",
      remote_connection_uuid: data["connection_uuid"] || data["connection_id"],
      http_status: 200,
      error: nil
    }
  end

  defp build_error_result(http_status, error, message \\ nil) do
    %{
      success: false,
      status: :failed,
      message: message || error,
      remote_connection_uuid: nil,
      http_status: http_status,
      error: error
    }
  end

  defp extract_error(body, default) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> default
    end
  end

  # `Finch.request/3` returns `{:error, Finch.error()}` where the struct is
  # `Finch.TransportError`, `Finch.HTTPError`, or `Finch.Error` — `Mint.*`
  # errors from the underlying client are wrapped via `Finch.Error.wrap/1`
  # before being returned. The `Finch.*` heads are gated with
  # `Code.ensure_loaded?/1` because Finch is a transitive dep (via
  # `:phoenix_kit`) and may not be compiled before this module in some
  # parent-app build orders, in which case the struct lookup would fail at
  # compile time.
  if Code.ensure_loaded?(Finch.TransportError) do
    defp format_error(%Finch.TransportError{reason: reason}) do
      "Connection failed: #{inspect(reason)}"
    end
  end

  if Code.ensure_loaded?(Finch.HTTPError) do
    defp format_error(%Finch.HTTPError{reason: reason}) do
      "HTTP error: #{inspect(reason)}"
    end
  end

  if Code.ensure_loaded?(Finch.Error) do
    defp format_error(%Finch.Error{reason: reason}) do
      "Finch error: #{inspect(reason)}"
    end
  end

  defp format_error({:exception, msg}) do
    "Exception: #{msg}"
  end

  defp format_error(reason) do
    inspect(reason)
  end

  defp update_connection_metadata(connection, result) do
    # Only update metadata for actual database structs (have :uuid field)
    # Skip for temp maps passed before connection is saved
    case Map.get(connection, :uuid) do
      nil ->
        # Temp map, nothing to update
        :ok

      _uuid ->
        current_metadata = Map.get(connection, :metadata) || %{}

        notification_data = %{
          "notified_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
          "notification_success" => result.success,
          "notification_status" => Atom.to_string(result.status),
          "notification_message" => result.message,
          "remote_connection_uuid" => result.remote_connection_uuid,
          "http_status" => result.http_status
        }

        updated_metadata = Map.put(current_metadata, "remote_notification", notification_data)

        # Update the connection with new metadata
        Connections.update_connection(connection, %{metadata: updated_metadata})
    end
  rescue
    e ->
      Logger.error("Failed to update connection metadata: #{Exception.message(e)}")
      :ok
  end

  defp import_table_data(table_name, data, conflict_strategy, target) when is_list(data) do
    repo = PhoenixKit.RepoHelper.repo()
    numeric_cols = fetch_numeric_columns(table_name)

    Logger.info("Sync: Importing #{length(data)} records into #{table_name}")

    # Execute raw SQL insert for each record
    results =
      Enum.reduce(data, new_import_acc(), fn record, acc ->
        insert_record(repo, table_name, record, conflict_strategy, numeric_cols, target)
        |> accumulate_import_result(acc)
      end)

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: #{results.errors} record(s) failed in #{table_name}")
    end

    finish_import_acc(results)
  end

  defp import_table_data(_table_name, _data, _strategy, _target) do
    %{imported: 0, skipped: 0, errors: 0}
  end

  defp import_table_data_with_remap(table_name, data, conflict_strategy, uuid_remap, target)
       when is_list(data) do
    repo = PhoenixKit.RepoHelper.repo()

    Logger.info("Sync: Importing #{length(data)} records into #{table_name} (with remap)")

    # Get FK info for this table
    fk_columns =
      case SchemaInspector.get_foreign_key_columns(table_name) do
        {:ok, fks} -> fks
        _ -> []
      end

    # Get unique columns for this table (for matching existing records)
    unique_sets =
      case SchemaInspector.get_unique_columns(table_name) do
        {:ok, sets} -> sets
        _ -> []
      end

    # Cache the numeric columns and their kind once per table, so the
    # per-value parsing in prepare_value/3 stays scoped to the columns where
    # a "3.14" really is a number: a %Decimal{} for numeric/decimal, a float
    # for double precision/real. Parsing every string column would mis-cast
    # version numbers or text labels and trip Postgrex type errors.
    numeric_cols = fetch_numeric_columns(table_name)

    import_ctx = %{
      repo: repo,
      table_name: table_name,
      pk_cols: target.pk_cols,
      target: target,
      fk_columns: fk_columns,
      unique_sets: unique_sets,
      numeric_cols: numeric_cols,
      conflict_strategy: conflict_strategy
    }

    {results, updated_remap} =
      Enum.reduce(
        data,
        {new_import_acc(), uuid_remap},
        fn record, {acc, remap} ->
          import_single_record_with_remap(import_ctx, record, acc, remap)
        end
      )

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: #{results.errors} record(s) failed in #{table_name}")
    end

    remap_additions = map_size(updated_remap) - map_size(uuid_remap)

    if remap_additions > 0 do
      Logger.info("Sync: Added #{remap_additions} UUID remap(s) from #{table_name}")
    end

    {finish_import_acc(results), updated_remap}
  end

  defp import_table_data_with_remap(_table_name, _data, _strategy, uuid_remap, _target) do
    {%{imported: 0, skipped: 0, errors: 0}, uuid_remap}
  end

  defp import_single_record_with_remap(ctx, record, acc, remap) do
    import_remap_record(ctx, record, acc, remap)
  rescue
    _ -> {%{acc | errors: acc.errors + 1}, remap}
  end

  defp import_remap_record(%{pk_cols: [pk_col]} = ctx, record, acc, remap)
       when is_map(record) do
    # FKs are remapped once, before matching: a unique set often holds an
    # FK (UNIQUE (parent_uuid, slug)), and only the remapped value can match
    # the local row. Remapping again at insert would follow a chain
    # (42 -> 7 -> 3) when one local key is also another row's sender key.
    sender_pk = get_record_field(record, pk_col)
    record = apply_fk_remap(record, ctx.fk_columns, remap, ctx.target.column_types)
    key_type = Map.get(ctx.target.column_types, pk_col)

    remap =
      remap_own_key(remap, ctx.table_name, sender_pk, get_record_field(record, pk_col), key_type)

    {match_action, remap} = match_existing_record(ctx, pk_col, record, sender_pk, remap)

    case match_action do
      :skip_matched ->
        Logger.debug("Sync: Skipped a #{ctx.table_name} record (matched existing)")
        {%{acc | skipped: acc.skipped + 1}, remap}

      {:update_matched, local_pk} ->
        # Same row under the local key: write the sender's values onto it
        # through the key conflict, per the strategy.
        record
        |> put_record_field(pk_col, local_pk)
        |> then(&insert_remapped(ctx, &1, acc, remap))

      :import ->
        insert_remapped(ctx, record, acc, remap)
    end
  end

  # Composite primary key (a table without one never gets here). The remap
  # is keyed by a single sender PK, so there is nothing of this row's own to
  # translate and nothing to add to the remap; nothing references a
  # composite key through it either. FK columns go through apply_fk_remap/4
  # as on the single-key path, then the insert resolves conflicts on the
  # whole key through ON CONFLICT, per the strategy.
  defp import_remap_record(ctx, record, acc, remap) when is_map(record) do
    remapped_record = apply_fk_remap(record, ctx.fk_columns, remap, ctx.target.column_types)

    updated_acc =
      insert_record(
        ctx.repo,
        ctx.table_name,
        remapped_record,
        ctx.conflict_strategy,
        ctx.numeric_cols,
        ctx.target
      )
      |> accumulate_import_result(acc)

    {updated_acc, remap}
  end

  defp import_remap_record(_ctx, _record, acc, remap),
    do: {%{acc | errors: acc.errors + 1}, remap}

  # The record's FKs are already remapped.
  defp insert_remapped(ctx, record, acc, remap) do
    updated_acc =
      insert_record(
        ctx.repo,
        ctx.table_name,
        record,
        ctx.conflict_strategy,
        ctx.numeric_cols,
        ctx.target
      )
      |> accumulate_import_result(acc)

    {updated_acc, remap}
  end

  # Matches a record against the local table, first by its own key, then by
  # unique columns. A unique-column match is the same row under another key:
  # it adds a remap (sender key -> local key) for the tables that reference
  # it. What happens to a matched row depends on the strategy: skip (and
  # append) leave it alone; overwrite and merge write the sender's values
  # onto it. Returns {:import | :skip_matched | {:update_matched, local_pk},
  # remap}. The remap is keyed by the sender's own key (`sender_pk`), which
  # is what other tables' FKs carry.
  defp match_existing_record(ctx, pk_col, record, sender_pk, remap) do
    %{repo: repo, table_name: table_name, unique_sets: unique_sets} = ctx
    record_pk = get_record_field(record, pk_col)
    updates? = ctx.conflict_strategy in ["overwrite", "merge"]

    column_types = ctx.target.column_types

    if check_pk_exists(repo, table_name, pk_col, record_pk, Map.get(column_types, pk_col)) do
      if updates?, do: {:import, remap}, else: {:skip_matched, remap}
    else
      case find_match_by_unique(repo, table_name, pk_col, record, unique_sets, column_types) do
        {:ok, local_pk} ->
          Logger.info("Sync: Matched a #{table_name} record by unique columns")
          key_type = Map.get(ctx.target.column_types, pk_col)
          remap = Map.put(remap, {table_name, remap_key(sender_pk, key_type)}, local_pk)
          {unique_match_action(updates?, local_pk), remap}

        :no_match ->
          {:import, remap}
      end
    end
  end

  # A key that is also an FK (profiles keyed by their user) was just
  # remapped with that FK, so the row lives here under another key: tables
  # that reference it by the sender's key follow the same remap.
  defp remap_own_key(remap, table_name, sender_pk, record_pk, key_type) do
    case {remap_key(sender_pk, key_type), remap_key(record_pk, key_type)} do
      {same, same} -> remap
      {nil, _} -> remap
      {sender_key, _} -> Map.put(remap, {table_name, sender_key}, record_pk)
    end
  end

  defp unique_match_action(true = _updates?, local_pk), do: {:update_matched, local_pk}
  defp unique_match_action(false = _updates?, _local_pk), do: :skip_matched

  # Canonicalise UUID columns only. Text keys that happen to be 16 bytes
  # or look like UUIDs must retain their bytes and case to stay distinct.
  defp remap_key(%{"__phoenix_kit_binary__" => encoded}, "uuid") when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> remap_key(bytes, "uuid")
      :error -> nil
    end
  end

  # Ecto.UUID.cast/1 takes both forms: 16 raw bytes and the 36-character
  # text, which it returns in lower case.
  defp remap_key(value, "uuid") when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp remap_key(value, _type) when is_binary(value), do: value
  defp remap_key(value, _type) when is_integer(value), do: Integer.to_string(value)
  defp remap_key(_value, _type), do: nil

  defp check_pk_exists(repo, table_name, pk_col, pk_value, key_type) do
    if SchemaInspector.valid_identifier?(table_name) and
         SchemaInspector.valid_identifier?(pk_col) do
      sql = ~s[SELECT 1 FROM "#{table_name}" WHERE "#{pk_col}" = $1 LIMIT 1]

      case SQL.query(repo, sql, [Prepare.key_value(pk_value, key_type)], log: false) do
        {:ok, %{num_rows: 1}} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp find_match_by_unique(_repo, _table_name, _pk_col, _record, [], _column_types),
    do: :no_match

  defp find_match_by_unique(repo, table_name, pk_col, record, [unique_cols | rest], column_types) do
    all_idents = [table_name, pk_col | unique_cols]

    # Defense-in-depth: even though pk_col and unique_cols come from
    # local schema introspection, table_name flows in from the import
    # path (where it can ultimately trace back to a sender's wire data
    # via pull_table_data_with_remap). Validate every dynamic identifier
    # before splicing it into a quoted SQL string. Failures fall through
    # to the next unique-constraint candidate, matching the existing
    # rescue semantics.
    if Enum.all?(all_idents, &SchemaInspector.valid_identifier?/1) do
      do_find_match_by_unique(repo, table_name, pk_col, record, unique_cols, rest, column_types)
    else
      find_match_by_unique(repo, table_name, pk_col, record, rest, column_types)
    end
  end

  defp do_find_match_by_unique(
         repo,
         table_name,
         pk_col,
         record,
         unique_cols,
         rest,
         column_types
       ) do
    # Get values for this unique constraint's columns
    col_values =
      Enum.map(unique_cols, fn col ->
        {col, get_record_field(record, col)}
      end)

    # Skip if any value is nil (can't match on nil)
    if Enum.any?(col_values, fn {_col, val} -> is_nil(val) end) do
      find_match_by_unique(repo, table_name, pk_col, record, rest, column_types)
    else
      where_clauses =
        col_values
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{col, _val}, idx} -> ~s["#{col}" = $#{idx}] end)

      values =
        Enum.map(col_values, fn {col, val} ->
          Prepare.key_value(val, Map.get(column_types, col))
        end)

      sql = ~s[SELECT "#{pk_col}" FROM "#{table_name}" WHERE #{where_clauses} LIMIT 1]

      case SQL.query(repo, sql, values, log: false) do
        {:ok, %{rows: [[local_pk]]}} -> {:ok, local_pk}
        _ -> find_match_by_unique(repo, table_name, pk_col, record, rest, column_types)
      end
    end
  rescue
    _ -> find_match_by_unique(repo, table_name, pk_col, record, rest, column_types)
  end

  # Apply FK remaps to a record before inserting
  defp apply_fk_remap(record, [], _remap, _column_types), do: record

  defp apply_fk_remap(record, fk_columns, remap, column_types) do
    Enum.reduce(fk_columns, record, fn %{column: col, referenced_table: ref_table}, rec ->
      remap_single_fk(rec, col, ref_table, remap, Map.get(column_types, col))
    end)
  end

  defp remap_single_fk(rec, col, ref_table, remap, key_type) do
    case remap_key(get_record_field(rec, col), key_type) do
      nil ->
        rec

      key ->
        case Map.fetch(remap, {ref_table, key}) do
          {:ok, local_value} ->
            Logger.debug("Sync: Remapped #{col} to a local #{ref_table} key")
            put_record_field(rec, col, local_value)

          :error ->
            rec
        end
    end
  end

  # An array column is named by its element type, which its values are
  # read by (Prepare.value/4).
  defp column_type(%{type: "ARRAY", element_type: element_type}), do: {:array, element_type}
  defp column_type(%{type: type}), do: type

  defp new_import_acc,
    do: %{imported: 0, skipped: 0, errors: 0, error_sample: nil, unknown_columns: MapSet.new()}

  # The error sample stays in the log: a database message can quote a row
  # value. Unknown column names already passed valid_identifier?/1 and say
  # nothing about the data, so they go back to the page.
  defp finish_import_acc(acc) do
    result = Map.drop(acc, [:error_sample, :unknown_columns])

    case Enum.sort(acc.unknown_columns) do
      [] -> result
      columns -> Map.put(result, :unknown_columns, columns)
    end
  end

  defp accumulate_import_result(:ok, acc), do: %{acc | imported: acc.imported + 1}
  defp accumulate_import_result(:skipped, acc), do: %{acc | skipped: acc.skipped + 1}
  defp accumulate_import_result(:error, acc), do: %{acc | errors: acc.errors + 1}

  defp accumulate_import_result({:error, {:unknown_columns, columns}}, acc) do
    acc = %{acc | unknown_columns: MapSet.union(acc.unknown_columns, MapSet.new(columns))}

    accumulate_import_result(
      {:error, "columns not in the local table: #{Enum.join(columns, ", ")}"},
      acc
    )
  end

  defp accumulate_import_result({:error, reason}, acc) do
    acc = if is_nil(acc.error_sample), do: %{acc | error_sample: reason}, else: acc
    %{acc | errors: acc.errors + 1}
  end

  defp insert_record(repo, table_name, record, conflict_strategy, numeric_cols, target)
       when is_map(record) do
    %{pk_cols: pk_cols, columns: local_columns} = target

    # For append strategy, strip a single-column primary key to let the DB
    # generate a new one. A composite key is natural data (lang + value),
    # which the DB cannot generate, so it stays.
    record =
      case {conflict_strategy, pk_cols} do
        {"append", [pk_col]} -> drop_record_field(record, pk_col)
        _ -> record
      end

    # Normalize all keys to strings for consistent SQL generation
    record = normalize_record_keys(record)
    columns = Map.keys(record)

    # Only names of this table's own columns reach the SQL. check_record_keys
    # already refused non-identifiers; a valid name the local table lacks
    # (schema drift) fails this record without a round trip.
    case {Enum.reject(columns, &MapSet.member?(local_columns, &1)),
          unsupported_value(record, target.column_types)} do
      {[], nil} ->
        do_insert_record(
          repo,
          table_name,
          record,
          columns,
          conflict_strategy,
          numeric_cols,
          target
        )

      {[], {column, type}} ->
        {:error, "column #{column} holds a #{type}, a type sync does not carry"}

      {unknown, _unsupported} ->
        {:error, {:unknown_columns, unknown}}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp insert_record(_repo, _table_name, _record, _strategy, _numeric_cols, _target), do: :error

  # The first value the sender marked as a type it cannot send
  # (ExtensionTypes), as `{column, type}`. In a json column the same shape
  # is just an object.
  defp unsupported_value(record, column_types) do
    Enum.find_value(record, fn {column, value} ->
      type = ExtensionTypes.unsupported(value)

      if type && Map.get(column_types, column) not in ["json", "jsonb"],
        do: {column, type}
    end)
  end

  defp do_insert_record(
         repo,
         table_name,
         record,
         columns,
         conflict_strategy,
         numeric_cols,
         %{pk_cols: pk_cols} = target
       ) do
    values =
      Enum.map(columns, fn col ->
        Prepare.value(Map.get(record, col), col, numeric_cols, target.column_types)
      end)

    placeholders =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(
        ", ",
        &placeholder(&1, record, columns, conflict_strategy, table_name, target)
      )

    columns_str = Enum.map_join(columns, ", ", &~s["#{&1}"])
    on_conflict = build_on_conflict_clause(conflict_strategy, table_name, pk_cols, columns)

    sql = ~s[INSERT INTO "#{table_name}" (#{columns_str}) VALUES (#{placeholders}) #{on_conflict}]

    execute_insert(repo, sql, values, conflict_strategy)
  end

  # Under merge a NULL means "keep what is here", but Postgres checks NOT
  # NULL on the proposed row before ON CONFLICT, so a NULL bound for a NOT
  # NULL column would fail a row the update was going to keep. Such a value
  # reads the local one instead: for an existing row the check passes and
  # the update keeps it; for a new row the subquery is NULL and the row
  # fails NOT NULL, as it should. The key's own placeholders are reused.
  defp placeholder({col, idx}, record, columns, "merge", table_name, target) do
    %{pk_cols: pk_cols, not_null: not_null} = target

    if is_nil(Map.get(record, col)) and MapSet.member?(not_null, col) and
         Enum.all?(pk_cols, &(&1 in columns)) do
      key_match =
        Enum.map_join(pk_cols, " AND ", fn pk ->
          ~s["#{pk}" = $#{Enum.find_index(columns, &(&1 == pk)) + 1}]
        end)

      ~s[COALESCE($#{idx}, (SELECT "#{col}" FROM "#{table_name}" WHERE #{key_match}))]
    else
      "$#{idx}"
    end
  end

  defp placeholder({_col, idx}, _record, _columns, _strategy, _table_name, _target), do: "$#{idx}"

  # overwrite takes every value the sender sent; merge keeps the local value
  # where the sender's is NULL. Both update through the key conflict.
  defp build_on_conflict_clause(strategy, table_name, [_ | _] = pk_cols, columns)
       when strategy in ["overwrite", "merge"] do
    case build_update_clause(strategy, table_name, columns, pk_cols) do
      "" ->
        "ON CONFLICT DO NOTHING"

      update ->
        conflict_target = Enum.map_join(pk_cols, ", ", &~s["#{&1}"])
        ~s[ON CONFLICT (#{conflict_target}) DO UPDATE SET #{update}]
    end
  end

  defp build_on_conflict_clause("append", _table_name, [_pk_col], _columns), do: ""

  defp build_on_conflict_clause(_strategy, _table_name, _pk_cols, _columns),
    do: "ON CONFLICT DO NOTHING"

  defp execute_insert(repo, sql, values, conflict_strategy) do
    case SQL.query(repo, sql, values, log: false) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        :skipped

      # overwrite and merge update through the key; a conflict on another
      # unique column is a row that is already here under another key, and
      # is skipped as skip's ON CONFLICT DO NOTHING would.
      {:error, %{postgres: %{code: :unique_violation}}}
      when conflict_strategy in ["overwrite", "merge"] ->
        :skipped

      {:error, %{postgres: %{code: code, message: msg}}} ->
        {:error, "[#{code}] #{msg}"}

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp build_update_clause(strategy, table_name, columns, pk_cols) do
    columns
    |> Enum.reject(&(to_string(&1) in pk_cols))
    |> Enum.map_join(", ", fn col ->
      case strategy do
        "merge" -> ~s["#{col}" = COALESCE(EXCLUDED."#{col}", "#{table_name}"."#{col}")]
        "overwrite" -> ~s["#{col}" = EXCLUDED."#{col}"]
      end
    end)
  end

  # Caps a response body at 500 bytes before it lands in a log line. Response
  # bodies can be arbitrarily large (JSON error payloads, HTML error pages
  # returned by misconfigured proxies, etc.); logging them unbounded
  # blows up log storage and can leak unrelated data that the remote
  # site's error page might include.
  @log_body_limit 500
  defp truncate_body(body) when is_binary(body) do
    case byte_size(body) do
      size when size <= @log_body_limit -> body
      size -> binary_part(body, 0, @log_body_limit) <> "…(#{size - @log_body_limit} more bytes)"
    end
  end

  # Value / record-transformation helpers live in ConnectionNotifier.Prepare.
  defp fetch_numeric_columns(table_name), do: Prepare.numeric_column_types(table_name)

  defp get_record_field(record, field), do: Prepare.get_field(record, field)
  defp put_record_field(record, field, value), do: Prepare.put_field(record, field, value)
  defp drop_record_field(record, field), do: Prepare.drop_field(record, field)
  defp normalize_record_keys(record), do: Prepare.normalize_keys(record)
end
