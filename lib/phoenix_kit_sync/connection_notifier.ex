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
  alias PhoenixKitSync.Connections
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
  - `{:ok, :not_found}` - Connection not found on remote
  - `{:ok, :offline}` - Remote site is offline
  - `{:error, reason}` - Failed to notify
  """
  def notify_status_change(connection, new_status, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
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
      {:ok, %{"success" => true, "status" => status}} -> {:ok, status}
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
  def fetch_sender_tables(connection, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_sender_tables(site_url, auth_token_hash, opts)
    end
  end

  defp do_fetch_sender_tables(site_url, auth_token_hash, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    api_url = build_list_tables_url(site_url)
    body = %{"auth_token_hash" => auth_token_hash}

    Logger.debug("Sync: Fetching tables from sender", %{sender_url: site_url})

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_tables_response(resp_body)

      result ->
        handle_api_http_result(result)
    end
  end

  defp parse_tables_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "tables" => tables}} ->
        {:ok, convert_tables_to_structs(tables)}

      {:ok, %{"success" => false, "error" => error}} ->
        {:error, error}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp convert_tables_to_structs(tables) do
    Enum.map(tables, fn t ->
      %{
        name: t["name"],
        row_count: t["row_count"] || 0,
        size_bytes: t["size_bytes"] || 0,
        checksum: t["checksum"],
        depends_on: t["depends_on"] || []
      }
    end)
  end

  @doc """
  Pulls data for a specific table from the sender.

  Called by receiver to fetch table data during sync.

  ## Parameters

  - `connection` - The receiver connection
  - `table_name` - Name of the table to pull
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 60_000ms for large data)
    - `:conflict_strategy` - How to handle existing records ("skip", "overwrite", "merge")

  ## Returns

  - `{:ok, result}` - Map with :records_imported, :records_skipped, etc.
  - `{:error, :offline}` - Sender is offline
  - `{:error, :table_missing_locally}` - The table does not exist on this
    site; nothing is requested from the sender
  - `{:error, :no_primary_key}` - The local table has no primary key; it is
    not pulled, since repeat pulls would duplicate rows
  - `{:error, :import_failed}` - Handling the response raised or exited; the
    transfer is marked failed and the details are in the log
  - `{:error, reason}` - Failed to pull
  """
  def pull_table_data(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      connection_uuid = Map.get(connection, :uuid)

      do_pull_table_data(
        site_url,
        auth_token_hash,
        connection_uuid,
        table_name,
        opts
      )
    end
  end

  @doc """
  Same as pull_table_data but accepts and returns a uuid_remap for FK remapping across tables.
  Returns {:ok, import_result, updated_remap} or {:error, reason, unchanged_remap},
  with the same error reasons as `pull_table_data/3`.
  """
  def pull_table_data_with_remap(connection, table_name, uuid_remap, opts \\ []) do
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
    timeout = Keyword.get(opts, :timeout, 60_000)
    conflict_strategy = Keyword.get(opts, :conflict_strategy, "skip")

    Logger.info("Sync: Pulling data for table #{table_name}", %{sender_url: site_url})

    {:ok, transfer} =
      create_pull_transfer(
        connection_uuid,
        table_name,
        site_url,
        conflict_strategy
      )

    api_url = build_pull_data_url(site_url)

    body = %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "conflict_strategy" => conflict_strategy
    }

    guard_transfer(transfer, table_name, &{:error, &1}, fn ->
      with {:ok, target} <- check_local_table(transfer, table_name) do
        result = make_http_request(api_url, body, timeout)
        handle_pull_response(result, transfer, table_name, {conflict_strategy, target})
      end
    end)
  end

  defp do_pull_table_data_with_remap(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         uuid_remap,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    conflict_strategy = Keyword.get(opts, :conflict_strategy, "skip")

    Logger.info("Sync: Pulling data for table #{table_name}", %{sender_url: site_url})

    {:ok, transfer} =
      create_pull_transfer(
        connection_uuid,
        table_name,
        site_url,
        conflict_strategy
      )

    api_url = build_pull_data_url(site_url)

    body = %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "conflict_strategy" => conflict_strategy
    }

    guard_transfer(transfer, table_name, &{:error, &1, uuid_remap}, fn ->
      case check_local_table(transfer, table_name) do
        {:ok, target} ->
          result = make_http_request(api_url, body, timeout)
          import_spec = {conflict_strategy, target}
          handle_pull_response_with_remap(result, transfer, table_name, import_spec, uuid_remap)

        {:error, reason} ->
          {:error, reason, uuid_remap}
      end
    end)
  end

  defp create_pull_transfer(
         connection_uuid,
         table_name,
         site_url,
         conflict_strategy
       ) do
    Transfers.create_transfer(%{
      direction: "receive",
      connection_uuid: connection_uuid,
      table_name: table_name,
      remote_site_url: site_url,
      conflict_strategy: conflict_strategy,
      status: "in_progress",
      started_at: UtilsDate.utc_now()
    })
  end

  defp handle_pull_response(
         {:ok, %{status: 200, body: resp_body}},
         transfer,
         table_name,
         import_spec
       ) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "data" => data}} ->
        complete_pull_transfer(transfer, table_name, data, import_spec)

      {:ok, %{"success" => false, "error" => error}} when is_binary(error) ->
        Logger.error("Sync: Pull failed - remote error: #{error}")
        Transfers.fail_transfer(transfer, error)
        {:error, error}

      {:ok, %{"success" => false}} ->
        fail_unreadable_remote_error(transfer)

      other ->
        Logger.error("Sync: Pull failed - invalid response format: #{inspect(other)}")
        Transfers.fail_transfer(transfer, "Invalid response from remote site")
        {:error, :invalid_response}
    end
  end

  defp handle_pull_response({:ok, %{status: 401}}, transfer, _table_name, _import_spec) do
    Logger.error("Sync: Pull failed - unauthorized (401)")
    Transfers.fail_transfer(transfer, "Unauthorized")
    {:error, :unauthorized}
  end

  defp handle_pull_response({:ok, %{status: 404}}, transfer, _table_name, _import_spec) do
    Logger.error("Sync: Pull failed - table not found (404)")
    Transfers.fail_transfer(transfer, "Table not found")
    {:error, :table_not_found}
  end

  defp handle_pull_response({:ok, %{status: status}}, transfer, _table_name, _import_spec) do
    Logger.error("Sync: Pull failed - HTTP error #{status}")
    Transfers.fail_transfer(transfer, "HTTP error #{status}")
    {:error, :unexpected_response}
  end

  defp handle_pull_response({:error, %{reason: reason}}, transfer, _table_name, _import_spec)
       when reason in [:econnrefused, :timeout, :nxdomain] do
    Logger.error("Sync: Pull failed - sender offline (#{reason})")
    Transfers.fail_transfer(transfer, "Sender offline")
    {:error, :offline}
  end

  defp handle_pull_response({:error, reason}, transfer, _table_name, _import_spec) do
    Logger.error("Sync: Pull failed - #{inspect(reason)}")
    Transfers.fail_transfer(transfer, inspect(reason))
    {:error, reason}
  end

  # Remap-aware versions that thread uuid_remap through
  defp handle_pull_response_with_remap(
         {:ok, %{status: 200, body: resp_body}},
         transfer,
         table_name,
         import_spec,
         uuid_remap
       ) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "data" => data}} ->
        complete_pull_transfer_with_remap(transfer, table_name, data, import_spec, uuid_remap)

      {:ok, %{"success" => false, "error" => error}} when is_binary(error) ->
        Logger.error("Sync: Pull failed - remote error: #{error}")
        Transfers.fail_transfer(transfer, error)
        {:error, error, uuid_remap}

      {:ok, %{"success" => false}} ->
        {:error, reason} = fail_unreadable_remote_error(transfer)
        {:error, reason, uuid_remap}

      other ->
        Logger.error("Sync: Pull failed - invalid response format: #{inspect(other)}")
        Transfers.fail_transfer(transfer, "Invalid response from remote site")
        {:error, :invalid_response, uuid_remap}
    end
  end

  defp handle_pull_response_with_remap(result, transfer, table_name, import_spec, uuid_remap) do
    case handle_pull_response(result, transfer, table_name, import_spec) do
      {:ok, import_result} -> {:ok, import_result, uuid_remap}
      {:error, reason} -> {:error, reason, uuid_remap}
    end
  end

  # A remote error that is not a string (a map, a list) is not shown or
  # stored: it is the sender's payload, and interpolating it would raise.
  defp fail_unreadable_remote_error(transfer) do
    Logger.error("Sync: Pull failed - remote sent an error that is not a string")
    Transfers.fail_transfer(transfer, "Invalid response from remote site")
    {:error, :invalid_response}
  end

  defp complete_pull_transfer(transfer, table_name, data, {conflict_strategy, target}) do
    with :ok <- check_record_keys(transfer, data) do
      import_result = import_table_data(table_name, data, conflict_strategy, target)

      Transfers.complete_transfer(transfer, %{
        records_transferred: length(data),
        records_created: import_result.imported,
        records_skipped: import_result.skipped,
        records_failed: import_result.errors
      })

      {:ok, import_result}
    end
  end

  defp complete_pull_transfer_with_remap(
         transfer,
         table_name,
         data,
         {conflict_strategy, target},
         uuid_remap
       ) do
    case check_record_keys(transfer, data) do
      :ok ->
        {import_result, updated_remap} =
          import_table_data_with_remap(table_name, data, conflict_strategy, uuid_remap, target)

        Transfers.complete_transfer(transfer, %{
          records_transferred: length(data),
          records_created: import_result.imported,
          records_skipped: import_result.skipped,
          records_failed: import_result.errors
        })

        {:ok, import_result, updated_remap}

      {:error, reason} ->
        {:error, reason, uuid_remap}
    end
  end

  # Checked before the request, so a table that cannot be imported here does
  # not spend the sender's download and record limits. A table missing on
  # this site has to be created first (Precise Transfer > Create Table).
  # Without a primary key there is nothing to detect a row that is already
  # here: every pull would insert the same rows again, so such a table is
  # not imported at all.
  defp check_local_table(transfer, table_name) do
    cond do
      # The name comes from the sender's table list: it is spliced into the
      # INSERT, so anything but a plain identifier stops here, unechoed.
      not SchemaInspector.valid_identifier?(table_name) ->
        reject_local_table(transfer, :invalid_table_name, "Invalid table name")

      not SchemaInspector.table_exists?(table_name) ->
        reject_local_table(
          transfer,
          :table_missing_locally,
          "Table #{table_name} does not exist here"
        )

      true ->
        case primary_key_columns(table_name) do
          [] -> reject_local_table(transfer, :no_primary_key, "No primary key on #{table_name}")
          pk_cols -> {:ok, %{pk_cols: pk_cols, columns: local_column_names(table_name)}}
        end
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
      Transfers.fail_transfer(transfer, "Invalid column name in sender data; not imported")
      {:error, :invalid_column_name}
    end
  end

  defp check_record_keys(_transfer, _data), do: :ok

  defp reject_local_table(transfer, reason, why) do
    Logger.warning("Sync: #{why}; not pulling it")
    Transfers.fail_transfer(transfer, "#{why}; not pulled")
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

  # The log gets the details; the transfer row and the returned reason get
  # only the table and the exception type, since an exception message can
  # quote row values. Rows inserted before the failure stay (each INSERT is
  # its own statement), and the transfer records no counts for them: those
  # counts lived in the import loop that raised.
  defp fail_import(transfer, table_name, kind, reason, stacktrace) do
    Logger.error(
      "Sync: Import of #{table_name} failed - " <>
        Exception.format(kind, reason, stacktrace)
    )

    Transfers.fail_transfer(
      transfer,
      "Import of #{table_name} failed (#{error_kind(kind, reason)})"
    )

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
  def fetch_table_schema(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_schema(site_url, auth_token_hash, table_name, opts)
    end
  end

  defp do_fetch_table_schema(site_url, auth_token_hash, table_name, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_schema_url(site_url)
    body = %{"auth_token_hash" => auth_token_hash, "table_name" => table_name}

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_schema_response(resp_body)

      result ->
        handle_table_http_result(result)
    end
  end

  defp parse_schema_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "schema" => schema}} -> {:ok, schema}
      {:ok, %{"success" => false, "error" => error}} -> {:error, error}
      _ -> {:error, :invalid_response}
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
  def fetch_table_records(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_records(site_url, auth_token_hash, table_name, opts)
    end
  end

  defp do_fetch_table_records(site_url, auth_token_hash, table_name, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_records_url(site_url)
    body = build_records_request_body(auth_token_hash, table_name, opts)

    case make_http_request(api_url, body, timeout) do
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
    |> maybe_add_ids(Keyword.get(opts, :ids))
    |> maybe_add_id_range(Keyword.get(opts, :id_range))
  end

  defp parse_records_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "records" => records}} -> {:ok, records}
      {:ok, %{"success" => false, "error" => error}} -> {:error, error}
      _ -> {:error, :invalid_response}
    end
  end

  defp maybe_add_ids(body, nil), do: body
  defp maybe_add_ids(body, []), do: body
  defp maybe_add_ids(body, ids), do: Map.put(body, "ids", ids)

  defp maybe_add_id_range(body, nil), do: body

  defp maybe_add_id_range(body, {start_id, end_id}) do
    Map.merge(body, %{"id_start" => start_id, "id_end" => end_id})
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

  defp handle_standard_http_result({:error, reason}), do: {:error, reason}

  defp handle_api_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_api_http_result({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_api_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_api_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_api_http_result({:error, reason}), do: {:error, reason}

  defp handle_table_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_table_http_result({:ok, %{status: 404}}), do: {:error, :table_not_found}
  defp handle_table_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_table_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_table_http_result({:error, reason}), do: {:error, reason}

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
    # Check if Finch is available
    finch_name = get_finch_name()

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    case Jason.encode(body) do
      {:ok, json_body} ->
        request = Finch.build(:post, url, headers, json_body)

        case Finch.request(request, finch_name,
               receive_timeout: timeout,
               pool_timeout: @connect_timeout
             ) do
          {:ok, %Finch.Response{status: status, body: response_body}} ->
            {:ok, %{status: status, body: response_body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp make_get_request(url, timeout) do
    finch_name = get_finch_name()

    headers = [
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, finch_name,
           receive_timeout: timeout,
           pool_timeout: @connect_timeout
         ) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
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
      Enum.reduce(data, %{imported: 0, skipped: 0, errors: 0, error_sample: nil}, fn record,
                                                                                     acc ->
        insert_record(repo, table_name, record, conflict_strategy, numeric_cols, target)
        |> accumulate_import_result(acc)
      end)

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: Sample error for #{table_name}: #{results.error_sample}")
    end

    Map.drop(results, [:error_sample])
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

    # Cache the set of numeric/decimal columns once per table so the per-value
    # decimal-string detection in prepare_value/3 stays scoped to the columns
    # where a "3.14" really is meant to become a %Decimal{}. Applying the
    # regex to every string column would mis-cast version numbers or text
    # labels and trip Postgrex type errors.
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
        {%{imported: 0, skipped: 0, errors: 0, error_sample: nil}, uuid_remap},
        fn record, {acc, remap} ->
          import_single_record_with_remap(import_ctx, record, acc, remap)
        end
      )

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: Sample error for #{table_name}: #{results.error_sample}")
    end

    remap_additions = map_size(updated_remap) - map_size(uuid_remap)

    if remap_additions > 0 do
      Logger.info("Sync: Added #{remap_additions} UUID remap(s) from #{table_name}")
    end

    {Map.drop(results, [:error_sample]), updated_remap}
  end

  defp import_table_data_with_remap(_table_name, _data, _strategy, uuid_remap, _target) do
    {%{imported: 0, skipped: 0, errors: 0}, uuid_remap}
  end

  defp import_single_record_with_remap(%{pk_cols: [pk_col]} = ctx, record, acc, remap) do
    record_pk = get_record_field(record, pk_col)

    {match_action, remap} =
      match_existing_record(ctx.repo, ctx.table_name, pk_col, record, ctx.unique_sets, remap)

    case match_action do
      :skip_matched ->
        Logger.debug("Sync: Skipped #{ctx.table_name} record #{record_pk} (matched existing)")
        {%{acc | skipped: acc.skipped + 1}, remap}

      :import ->
        remapped_record = apply_fk_remap(record, ctx.fk_columns, remap)

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
  end

  # Composite primary key (a table without one never gets here). The remap
  # is keyed by a single sender PK, so there is nothing of this row's own to
  # translate and nothing to add to the remap; nothing references a
  # composite key through it either. FK columns go through apply_fk_remap/3
  # as on the single-key path, which today rewrites only string-valued keys
  # (text columns): a uuid FK arrives as a wrapped binary and passes through
  # unchanged. Then the insert resolves conflicts on the whole key through
  # ON CONFLICT, per the strategy.
  defp import_single_record_with_remap(ctx, record, acc, remap) do
    remapped_record = apply_fk_remap(record, ctx.fk_columns, remap)

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

  # Try to match a record by unique columns to an existing local record.
  # If matched, adds a PK remap (sender_pk → local_pk) and returns :skip_matched.
  # If no match, returns :import.
  defp match_existing_record(repo, table_name, pk_col, record, unique_sets, remap) do
    record_pk = get_record_field(record, pk_col)

    # First check if this PK already exists locally
    case check_pk_exists(repo, table_name, pk_col, record_pk) do
      true ->
        # PK exists — skip, the ON CONFLICT clause would handle it anyway but
        # this avoids an unnecessary INSERT attempt
        {:skip_matched, remap}

      false ->
        # PK doesn't exist — try to match by unique columns
        case find_match_by_unique(repo, table_name, pk_col, record, unique_sets) do
          {:ok, local_pk} ->
            # Found a match! Record the remap and skip import
            remap_key = {table_name, stringify_pk(record_pk)}
            remap = Map.put(remap, remap_key, stringify_pk(local_pk))

            Logger.info(
              "Sync: Matched #{table_name} by unique columns: #{inspect(record_pk)} → #{inspect(local_pk)}"
            )

            {:skip_matched, remap}

          :no_match ->
            # No match — import as new record
            {:import, remap}
        end
    end
  end

  defp stringify_pk(pk) when is_binary(pk), do: pk
  defp stringify_pk(pk), do: inspect(pk)

  defp check_pk_exists(repo, table_name, pk_col, pk_value) do
    if SchemaInspector.valid_identifier?(table_name) and
         SchemaInspector.valid_identifier?(pk_col) do
      sql = ~s[SELECT 1 FROM "#{table_name}" WHERE "#{pk_col}" = $1 LIMIT 1]

      case SQL.query(repo, sql, [prepare_value(pk_value)]) do
        {:ok, %{num_rows: 1}} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp find_match_by_unique(_repo, _table_name, _pk_col, _record, []), do: :no_match

  defp find_match_by_unique(repo, table_name, pk_col, record, [unique_cols | rest]) do
    all_idents = [table_name, pk_col | unique_cols]

    # Defense-in-depth: even though pk_col and unique_cols come from
    # local schema introspection, table_name flows in from the import
    # path (where it can ultimately trace back to a sender's wire data
    # via pull_table_data_with_remap). Validate every dynamic identifier
    # before splicing it into a quoted SQL string. Failures fall through
    # to the next unique-constraint candidate, matching the existing
    # rescue semantics.
    if Enum.all?(all_idents, &SchemaInspector.valid_identifier?/1) do
      do_find_match_by_unique(repo, table_name, pk_col, record, unique_cols, rest)
    else
      find_match_by_unique(repo, table_name, pk_col, record, rest)
    end
  end

  defp do_find_match_by_unique(repo, table_name, pk_col, record, unique_cols, rest) do
    # Get values for this unique constraint's columns
    col_values =
      Enum.map(unique_cols, fn col ->
        {col, get_record_field(record, col)}
      end)

    # Skip if any value is nil (can't match on nil)
    if Enum.any?(col_values, fn {_col, val} -> is_nil(val) end) do
      find_match_by_unique(repo, table_name, pk_col, record, rest)
    else
      where_clauses =
        col_values
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{col, _val}, idx} -> ~s["#{col}" = $#{idx}] end)

      values = Enum.map(col_values, fn {_col, val} -> prepare_value(val) end)

      sql = ~s[SELECT "#{pk_col}" FROM "#{table_name}" WHERE #{where_clauses} LIMIT 1]

      case SQL.query(repo, sql, values) do
        {:ok, %{rows: [[local_pk]]}} -> {:ok, local_pk}
        _ -> find_match_by_unique(repo, table_name, pk_col, record, rest)
      end
    end
  rescue
    _ -> find_match_by_unique(repo, table_name, pk_col, record, rest)
  end

  # Apply FK remaps to a record before inserting
  defp apply_fk_remap(record, [], _remap), do: record

  defp apply_fk_remap(record, fk_columns, remap) do
    Enum.reduce(fk_columns, record, fn %{column: col, referenced_table: ref_table}, rec ->
      remap_single_fk(rec, col, ref_table, remap)
    end)
  end

  defp remap_single_fk(rec, col, ref_table, remap) do
    fk_value = get_record_field(rec, col)

    if fk_value && is_binary(fk_value) do
      case Map.get(remap, {ref_table, fk_value}) do
        nil ->
          rec

        local_value ->
          Logger.debug("Sync: Remapped #{col}: #{fk_value} → #{local_value}")
          put_record_field(rec, col, local_value)
      end
    else
      rec
    end
  end

  defp accumulate_import_result(:ok, acc), do: %{acc | imported: acc.imported + 1}
  defp accumulate_import_result(:skipped, acc), do: %{acc | skipped: acc.skipped + 1}
  defp accumulate_import_result(:error, acc), do: %{acc | errors: acc.errors + 1}

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
    case Enum.reject(columns, &MapSet.member?(local_columns, &1)) do
      [] ->
        do_insert_record(
          repo,
          table_name,
          record,
          columns,
          conflict_strategy,
          numeric_cols,
          pk_cols
        )

      unknown ->
        {:error, "columns not in the local table: #{Enum.join(unknown, ", ")}"}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp insert_record(_repo, _table_name, _record, _strategy, _numeric_cols, _target), do: :error

  defp do_insert_record(
         repo,
         table_name,
         record,
         columns,
         conflict_strategy,
         numeric_cols,
         pk_cols
       ) do
    values =
      Enum.map(columns, fn col ->
        prepare_value(Map.get(record, col), col, numeric_cols)
      end)

    placeholders =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_col, idx} -> "$#{idx}" end)

    columns_str = Enum.map_join(columns, ", ", &~s["#{&1}"])
    on_conflict = build_on_conflict_clause(conflict_strategy, pk_cols, columns)

    sql = ~s[INSERT INTO "#{table_name}" (#{columns_str}) VALUES (#{placeholders}) #{on_conflict}]

    execute_insert(repo, sql, values)
  end

  defp build_on_conflict_clause("overwrite", [_ | _] = pk_cols, columns) do
    case build_update_clause(columns, pk_cols) do
      "" ->
        "ON CONFLICT DO NOTHING"

      update ->
        conflict_target = Enum.map_join(pk_cols, ", ", &~s["#{&1}"])
        ~s[ON CONFLICT (#{conflict_target}) DO UPDATE SET #{update}]
    end
  end

  defp build_on_conflict_clause("append", [_pk_col], _columns), do: ""
  defp build_on_conflict_clause(_strategy, _pk_cols, _columns), do: "ON CONFLICT DO NOTHING"

  defp execute_insert(repo, sql, values) do
    case SQL.query(repo, sql, values) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        :skipped

      {:error, %{postgres: %{code: code, message: msg}}} ->
        {:error, "[#{code}] #{msg}"}

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp build_update_clause(columns, pk_cols) do
    columns
    |> Enum.reject(&(to_string(&1) in pk_cols))
    |> Enum.map_join(", ", fn col -> ~s["#{col}" = EXCLUDED."#{col}"] end)
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
  # Local aliases keep the call-site shape unchanged.
  alias PhoenixKitSync.ConnectionNotifier.Prepare

  defp prepare_value(value, column, numeric_cols),
    do: Prepare.value(value, column, numeric_cols)

  defp prepare_value(value), do: Prepare.value(value)
  defp fetch_numeric_columns(table_name), do: Prepare.numeric_columns(table_name)

  defp local_column_names(table_name) do
    case SchemaInspector.get_schema(table_name) do
      {:ok, %{columns: columns}} -> MapSet.new(columns, & &1.name)
      {:error, reason} -> raise "column lookup for #{table_name} failed: #{inspect(reason)}"
    end
  end

  defp primary_key_columns(table_name) do
    case SchemaInspector.get_primary_key(table_name) do
      {:ok, pk_cols} -> pk_cols
      {:error, reason} -> raise "primary key lookup for #{table_name} failed: #{inspect(reason)}"
    end
  end

  defp get_record_field(record, field), do: Prepare.get_field(record, field)
  defp put_record_field(record, field, value), do: Prepare.put_field(record, field, value)
  defp drop_record_field(record, field), do: Prepare.drop_field(record, field)
  defp normalize_record_keys(record), do: Prepare.normalize_keys(record)
end
