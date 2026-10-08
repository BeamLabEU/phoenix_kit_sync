defmodule PhoenixKitSync.Web.ApiController do
  @moduledoc """
  API controller for Sync cross-site operations.

  Handles incoming connection registration requests from remote PhoenixKit sites.
  When a remote site creates a sender connection pointing to this site, they call
  this API to automatically register the connection here.

  ## Security

  - Incoming connection mode controls how requests are handled
  - Optional password protection for incoming connections
  - All connections are logged with remote site information

  ## Endpoints

  - `POST /{prefix}/sync/api/register-connection` - Register incoming connection
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitSync
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Transfers

  @doc """
  Registers an incoming connection from a remote site.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `connection_name` (required) - Name for the connection
  - `auth_token` (required) - The auth token for the connection
  - `password` (optional) - Password if this site requires one

  ## Responses

  - 200 OK - Connection registered successfully
  - 400 Bad Request - Missing required fields
  - 401 Unauthorized - Invalid password
  - 403 Forbidden - Incoming connections are denied
  - 409 Conflict - Connection already exists for this site
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def register_connection(conn, params) do
    remote_ip = get_remote_ip(conn)

    Logger.info(
      "[Sync.API] register_connection called " <>
        "| sender_url=#{params["sender_url"]} " <>
        "| connection_name=#{inspect(params["connection_name"])} " <>
        "| has_auth_token=#{params["auth_token"] != nil} " <>
        "| has_password=#{params["password"] != nil} " <>
        "| remote_ip=#{remote_ip}"
    )

    with :ok <- check_module_enabled(),
         :ok <- check_incoming_allowed(),
         {:ok, validated_params} <- validate_params(params),
         :ok <- validate_password(params["password"]),
         {:ok, result} <- create_incoming_connection(validated_params, conn) do
      Logger.info(
        "[Sync.API] Connection registered successfully " <>
          "| sender_url=#{validated_params.sender_url} " <>
          "| connection_name=#{inspect(validated_params.connection_name)} " <>
          "| connection_uuid=#{result.connection_uuid} " <>
          "| status=#{result.status} " <>
          "| remote_ip=#{remote_ip}"
      )

      conn
      |> put_status(200)
      |> json(%{
        success: true,
        message: result.message,
        connection_status: result.status,
        connection_uuid: result.connection_uuid
      })
    else
      {:error, :module_disabled} ->
        Logger.warning("[Sync.API] register_connection rejected: module disabled")
        render_json_error(conn, 503, :module_disabled)

      {:error, :incoming_denied} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: incoming denied " <>
            "| sender_url=#{params["sender_url"]} " <>
            "| incoming_mode=#{PhoenixKitSync.get_incoming_mode()}"
        )

        render_json_error(conn, 403, :incoming_denied)

      {:error, :missing_fields, fields} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: missing fields " <>
            "| fields=#{inspect(fields)} " <>
            "| params_keys=#{inspect(Map.keys(params))}"
        )

        render_json_error(conn, 400, :missing_fields, %{fields: fields})

      {:error, :invalid_password} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: invalid password " <>
            "| sender_url=#{params["sender_url"]}"
        )

        render_json_error(conn, 401, :invalid_password)

      {:error, :password_required} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: password required " <>
            "| sender_url=#{params["sender_url"]}"
        )

        render_json_error(conn, 401, :password_required)

      {:error, :connection_exists} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: already exists " <>
            "| sender_url=#{params["sender_url"]}"
        )

        render_json_error(conn, 409, :connection_exists)

      {:error, reason} ->
        Logger.error(
          "[Sync.API] register_connection failed " <>
            "| sender_url=#{params["sender_url"]} " <>
            "| error=#{inspect(reason)}"
        )

        render_json_error(conn, 500, :fetch_failed)
    end
  end

  # Renders a standardised JSON error response. Status is the HTTP status
  # code; reason is an atom from PhoenixKitSync.Errors — dispatches through
  # Errors.message/1 so every API error string is centrally translated and
  # consistent. extras is merged into the response body (e.g. `:fields` for
  # missing-field details).
  defp render_json_error(conn, status, reason, extras \\ %{}) do
    body =
      %{success: false, error: Errors.message(reason)}
      |> Map.merge(extras)

    conn
    |> put_status(status)
    |> json(body)
  end

  @doc """
  Health check endpoint for DB Sync API.

  Returns whether the module is enabled and accepting connections.
  """
  def status(conn, _params) do
    config = PhoenixKitSync.get_config()

    conn
    |> put_status(200)
    |> json(%{
      enabled: config.enabled,
      incoming_mode: config.incoming_mode,
      password_required: config.incoming_mode == "require_password"
    })
  end

  @doc """
  Deletes a connection when requested by the remote site.

  Called when a receiver deletes their connection - the sender should also delete.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Connection deleted successfully
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def delete_connection(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_delete_params(params),
         {:ok, connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash),
         {:ok, _deleted} <- Connections.delete_connection(connection) do
      Logger.info("Connection deleted via API", %{
        sender_url: validated.sender_url,
        connection_uuid: connection.uuid
      })

      conn
      |> put_status(200)
      |> json(%{success: true, message: "Connection deleted"})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})

      {:error, reason} ->
        Logger.error("Failed to delete connection via API", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to delete connection"})
    end
  end

  @doc """
  Updates the status of a connection when notified by the sender.

  Called when the sender suspends, reactivates, or revokes their connection.
  The receiver should mirror the status change.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `status` (required) - The new status ("active", "suspended", "revoked")

  ## Responses

  - 200 OK - Status updated successfully
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def update_status(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_status_params(params),
         {:ok, connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash),
         {:ok, updated} <- update_connection_status(connection, validated.status) do
      Logger.info("Connection status updated via API", %{
        sender_url: validated.sender_url,
        connection_uuid: connection.uuid,
        new_status: validated.status
      })

      # PubSub broadcast handled by Connections.update_connection

      conn
      |> put_status(200)
      |> json(%{success: true, message: "Status updated to #{updated.status}"})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :invalid_status} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Invalid status value"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})

      {:error, reason} ->
        Logger.error("Failed to update connection status via API", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to update status"})
    end
  end

  @doc """
  Verifies a connection still exists.

  Called by sender to check if receiver still has the connection.
  Used for self-healing when the receiver was offline during delete.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Connection exists
  - 404 Not Found - Connection not found (deleted)
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def verify_connection(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_delete_params(params),
         {:ok, _connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash) do
      conn
      |> put_status(200)
      |> json(%{success: true, exists: true})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, exists: false})
    end
  end

  @doc """
  Returns the current status of a connection.

  Called by receiver to get the sender's current connection status.
  This allows receivers to sync their status with the sender.

  Expected JSON body:
  - `receiver_url` (required) - URL of the receiver site requesting status
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Returns connection status
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def get_connection_status(conn, params) do
    # Don't inspect the full params map — it contains `auth_token_hash`
    # which is a sensitive credential. Log only the safe fields.
    Logger.info(
      "[Sync.API] get_connection_status called " <>
        "| receiver_url=#{inspect(params["receiver_url"])} " <>
        "| has_token_hash=#{params["auth_token_hash"] != nil}"
    )

    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_get_status_params(params),
         {:ok, connection} <-
           find_sender_connection(validated.receiver_url, validated.auth_token_hash) do
      # If connection is pending, activate it since receiver is now querying
      # This confirms the connection is working
      {updated_connection, status} = maybe_activate_pending_connection(connection)

      Logger.info(
        "Sync API: Found sender connection #{updated_connection.uuid} with status '#{status}'"
      )

      conn
      |> put_status(200)
      |> json(%{
        success: true,
        status: status,
        name: updated_connection.name
      })
    else
      {:error, :module_disabled} ->
        Logger.warning("Sync API: get_connection_status - module disabled")

        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        Logger.warning("Sync API: get_connection_status - missing fields: #{inspect(fields)}")

        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        Logger.warning(
          "Sync API: get_connection_status - connection not found " <>
            "| has_token_hash=#{params["auth_token_hash"] != nil}"
        )

        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})
    end
  end

  @doc """
  Lists available tables for sync.

  Called by receiver to get a list of tables that can be synced from this sender.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Returns list of tables with row counts and sizes
  - 401 Unauthorized - Invalid auth token
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def list_tables(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_list_tables_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection) do
      # Authorization: even with a valid token, only return tables this
      # particular connection is allowed to see (excluded_tables blocklist
      # AND, if set, the allowed_tables allowlist). Without this filter a
      # leaked token would grant blanket DB access regardless of the
      # connection's intended scope.
      tables =
        get_syncable_tables()
        |> Enum.filter(fn table ->
          name = Map.get(table, :name) || Map.get(table, "name")
          PhoenixKitSync.Connection.table_allowed?(connection, name)
        end)

      # Update last_connected_at
      Connections.update_connection(connection, %{last_connected_at: UtilsDate.utc_now()})

      conn
      |> put_status(200)
      |> json(%{success: true, tables: tables})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})
    end
  end

  @doc """
  Pulls data for a specific table.

  Called by receiver to fetch table data during sync.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `table_name` (required) - Name of the table to pull
  - `conflict_strategy` (optional) - How to handle conflicts (skip, overwrite, merge)

  ## Responses

  - 200 OK - Returns table data
  - 401 Unauthorized - Invalid auth token
  - 404 Not Found - Table not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def pull_data(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_pull_data_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection),
         :ok <- check_table_allowed(connection, validated.table_name),
         {:ok, data} <- fetch_table_data(validated.table_name, connection) do
      # Update connection stats
      record_count = length(data)

      Connections.update_connection(connection, %{
        last_transfer_at: UtilsDate.utc_now(),
        downloads_used: (connection.downloads_used || 0) + 1,
        records_downloaded: (connection.records_downloaded || 0) + record_count,
        total_transfers: (connection.total_transfers || 0) + 1,
        total_records_transferred: (connection.total_records_transferred || 0) + record_count
      })

      # Record the transfer in history (sender side)
      Transfers.create_transfer(%{
        direction: "send",
        connection_uuid: connection.uuid,
        table_name: validated.table_name,
        remote_site_url: connection.site_url,
        conflict_strategy: validated.conflict_strategy,
        status: "completed",
        started_at: UtilsDate.utc_now(),
        completed_at: UtilsDate.utc_now(),
        records_transferred: record_count
      })

      Logger.info("Sending #{record_count} records for table #{validated.table_name}")

      conn
      |> put_status(200)
      |> json(%{success: true, table: validated.table_name, data: data})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :table_not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Table not found"})

      {:error, :table_not_allowed} ->
        render_json_error(conn, 403, :table_not_allowed)

      {:error, reason} ->
        Logger.error("Failed to pull data", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to pull data"})
    end
  end

  @doc """
  Returns schema for a specific table.

  Expected JSON body:
  - `auth_token_hash` - Hash of the auth token
  - `table_name` - Name of the table

  Returns:
  - 200 OK with schema data
  - 401 Unauthorized
  - 404 Not Found
  """
  def table_schema(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_schema_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection),
         :ok <- check_table_allowed(connection, validated.table_name) do
      table_name = validated.table_name

      # Check if table is in syncable list
      case get_table_schema(table_name) do
        {:ok, schema} ->
          conn
          |> put_status(200)
          |> json(%{success: true, schema: schema})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{success: false, error: "Table not found"})
      end
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields: #{Enum.join(fields, ", ")}"})

      {:error, :table_not_allowed} ->
        render_json_error(conn, 403, :table_not_allowed)
    end
  end

  @doc """
  Returns records from a specific table for preview.

  Expected JSON body:
  - `auth_token_hash` - Hash of the auth token
  - `table_name` - Name of the table
  - `limit` - Maximum number of records (default: 10)
  - `offset` - Offset for pagination (default: 0)
  - `ids` (optional) - List of specific IDs to fetch
  - `id_start`, `id_end` (optional) - ID range filter

  Returns:
  - 200 OK with records
  - 401 Unauthorized
  - 404 Not Found
  """
  def table_records(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_records_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection),
         :ok <- check_table_allowed(connection, validated.table_name) do
      table_name = validated.table_name
      limit = min(validated.limit, 100)
      offset = validated.offset

      # Build filter options
      filter_opts =
        []
        |> maybe_add_filter(:ids, validated[:ids])
        |> maybe_add_filter(:id_start, validated[:id_start])
        |> maybe_add_filter(:id_end, validated[:id_end])

      case get_table_records(table_name, limit, offset, filter_opts) do
        {:ok, records} ->
          conn
          |> put_status(200)
          |> json(%{success: true, records: records})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{success: false, error: "Table not found"})

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{success: false, error: "Failed to get records: #{inspect(reason)}"})
      end
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields: #{Enum.join(fields, ", ")}"})

      {:error, :table_not_allowed} ->
        render_json_error(conn, 403, :table_not_allowed)
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: [{key, value} | opts]

  # --- Private Functions ---

  defp maybe_activate_pending_connection(%{status: "pending"} = connection) do
    Logger.info(
      "[Sync.API] Auto-activating pending sender connection " <>
        "| uuid=#{connection.uuid} " <>
        "| name=#{inspect(connection.name)} " <>
        "| reason=receiver_queried_status"
    )

    now = UtilsDate.utc_now()

    case Connections.update_connection(connection, %{
           status: "active",
           approved_at: now,
           metadata:
             Map.merge(connection.metadata || %{}, %{
               "auto_activated" => true,
               "auto_activated_at" => DateTime.to_iso8601(now),
               "auto_activated_reason" => "receiver queried connection status"
             })
         }) do
      {:ok, updated} ->
        # PubSub broadcast handled by Connections.update_connection
        {updated, "active"}

      {:error, reason} ->
        Logger.error(
          "[Sync.API] Failed to auto-activate connection " <>
            "| uuid=#{connection.uuid} " <>
            "| error=#{inspect(reason)}"
        )

        {connection, connection.status}
    end
  end

  defp maybe_activate_pending_connection(connection) do
    {connection, connection.status}
  end

  defp check_module_enabled do
    if PhoenixKitSync.enabled?() do
      :ok
    else
      {:error, :module_disabled}
    end
  end

  defp check_incoming_allowed do
    case PhoenixKitSync.get_incoming_mode() do
      "deny_all" -> {:error, :incoming_denied}
      _ -> :ok
    end
  end

  # Validators live in ApiController.Validators. Local thin wrappers keep
  # the existing call-site names.
  alias PhoenixKitSync.Web.ApiController.Validators

  defp validate_params(params), do: Validators.validate_register(params)
  defp validate_delete_params(params), do: Validators.validate_delete(params)
  defp validate_get_status_params(params), do: Validators.validate_get_status(params)
  defp validate_status_params(params), do: Validators.validate_status(params)

  defp find_connection_by_hash(sender_url, auth_token_hash) do
    case Connections.find_by_site_url_and_hash(sender_url, auth_token_hash) do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  # Find a sender connection by token hash
  # The receiver is asking "what's the status of my connection to you?"
  # We look for our sender connection with matching hash (ignores receiver_url since it may be unreliable)
  defp find_sender_connection(_receiver_url, auth_token_hash) do
    # We're the sender, look for our sender connection with this hash
    case Connections.find_by_hash_and_direction(auth_token_hash, "sender") do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp update_connection_status(connection, new_status) do
    Connections.update_connection(connection, %{status: new_status})
  end

  defp validate_password(provided_password) do
    case PhoenixKitSync.get_incoming_mode() do
      "require_password" ->
        stored_password = PhoenixKitSync.get_incoming_password()

        cond do
          is_nil(stored_password) or stored_password == "" ->
            # Mode requires a password but none is configured. Refuse to
            # auto-accept (the previous behaviour was a silent bypass —
            # any registration would succeed if the admin enabled the
            # mode but forgot to set the password). Require an admin to
            # complete the configuration before any incoming registration
            # can proceed.
            Logger.warning(
              "[Sync.API] Refusing registration: incoming_mode=require_password but no password is configured"
            )

            {:error, :password_required}

          is_nil(provided_password) or provided_password == "" ->
            {:error, :password_required}

          Plug.Crypto.secure_compare(provided_password, stored_password) ->
            :ok

          true ->
            {:error, :invalid_password}
        end

      _ ->
        :ok
    end
  end

  defp create_incoming_connection(params, conn) do
    # Check if connection already exists from this sender
    existing = Connections.find_by_site_url(params.sender_url, "receiver")

    if existing do
      Logger.info(
        "[Sync.API] Incoming connection already exists " <>
          "| sender_url=#{params.sender_url} " <>
          "| existing_uuid=#{existing.uuid} " <>
          "| existing_status=#{existing.status}"
      )

      {:error, :connection_exists}
    else
      do_create_incoming_connection(params, conn)
    end
  end

  defp do_create_incoming_connection(params, conn) do
    # If we get here, the connection was approved (passed mode/password checks)
    # So it should be active - the sender already approved by creating their connection
    initial_status = "active"
    remote_ip = get_remote_ip(conn)
    user_agent = get_user_agent(conn)

    # Build connection attributes (use string keys to match form params)
    attrs = %{
      "name" => "From: #{params.connection_name}",
      "direction" => "receiver",
      "site_url" => params.sender_url,
      "auth_token" => params.auth_token,
      "status" => initial_status,
      "approval_mode" => "auto_approve",
      "metadata" => %{
        "registered_via" => "api",
        "registered_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "remote_ip" => remote_ip,
        "user_agent" => user_agent
      }
    }

    Logger.info(
      "[Sync.API] Creating incoming connection " <>
        "| sender_url=#{params.sender_url} " <>
        "| connection_name=#{inspect(params.connection_name)} " <>
        "| initial_status=#{initial_status} " <>
        "| remote_ip=#{remote_ip}"
    )

    case Connections.create_connection(attrs) do
      {:ok, connection, _token} ->
        Logger.info(
          "[Sync.API] Incoming connection created " <>
            "| uuid=#{connection.uuid} " <>
            "| site_url=#{connection.site_url} " <>
            "| auth_token_hash=#{String.slice(connection.auth_token_hash || "", 0, 8)}… " <>
            "| status=#{connection.status}"
        )

        # PubSub broadcast handled by Connections.create_connection

        {:ok,
         %{
           status: initial_status,
           message: "Connection registered and activated",
           connection_uuid: connection.uuid
         }}

      {:error, changeset} ->
        Logger.error(
          "[Sync.API] Failed to create incoming connection " <>
            "| sender_url=#{params.sender_url} " <>
            "| errors=#{inspect(changeset.errors)}"
        )

        {:error, {:changeset_error, changeset}}
    end
  end

  defp get_remote_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded_ips] ->
        forwarded_ips
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua] -> ua
      [] -> "unknown"
    end
  end

  defp validate_list_tables_params(params), do: Validators.validate_list_tables(params)
  defp validate_pull_data_params(params), do: Validators.validate_pull_data(params)

  defp find_sender_by_hash(auth_token_hash) do
    case Connections.find_by_hash_and_direction(auth_token_hash, "sender") do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp check_connection_active(connection) do
    if connection.status == "active" do
      :ok
    else
      {:error, :connection_not_active}
    end
  end

  # Per-connection table authorization. Even with a valid auth token, a
  # connection can only access tables that pass its excluded_tables /
  # allowed_tables filter. Returns `{:error, :table_not_allowed}` so the
  # action's `with` chain rejects with a 403 (handled in each error case).
  defp check_table_allowed(connection, table_name) do
    if PhoenixKitSync.Connection.table_allowed?(connection, table_name) do
      :ok
    else
      {:error, :table_not_allowed}
    end
  end

  defp get_syncable_tables do
    repo = PhoenixKit.RepoHelper.repo()

    # Get list of tables from the database
    # Filter to only include PhoenixKit tables that are allowed for sync
    tables_query = """
    SELECT
      t.table_name as name,
      pg_total_relation_size(c.oid) as size_bytes
    FROM information_schema.tables t
    JOIN pg_class c ON c.relname = t.table_name
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND t.table_name NOT LIKE 'schema_%'
      AND t.table_name NOT LIKE 'pg_%'
    ORDER BY t.table_name
    """

    # Get FK dependency map
    fk_map =
      case SchemaInspector.get_all_foreign_keys() do
        {:ok, map} -> map
        _ -> %{}
      end

    case SQL.query(repo, tables_query, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [name, size_bytes] ->
          build_table_info(repo, name, size_bytes, fk_map)
        end)

      {:error, _} ->
        []
    end
  rescue
    e ->
      Logger.error("[Sync.API] get_syncable_tables crashed: #{inspect(e)}")
      []
  end

  defp build_table_info(repo, name, size_bytes, fk_map) do
    row_count = get_actual_row_count(repo, name)

    checksum =
      case SchemaInspector.get_table_checksum(name) do
        {:ok, cs} when is_binary(cs) -> cs
        _ -> nil
      end

    %{
      "name" => name,
      "row_count" => row_count,
      "size_bytes" => size_bytes,
      "checksum" => checksum,
      "depends_on" => Map.get(fk_map, name, [])
    }
  end

  defp get_actual_row_count(repo, table_name) do
    # Validate table name to prevent SQL injection
    if SchemaInspector.valid_identifier?(table_name) do
      count_query = "SELECT COUNT(*) FROM #{quote_ident(table_name)}"

      case SQL.query(repo, count_query, []) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
    else
      0
    end
  rescue
    e ->
      Logger.error(
        "[Sync.API] get_actual_row_count crashed for #{inspect(table_name)}: #{inspect(e)}"
      )

      0
  end

  defp fetch_table_data(table_name, connection) do
    if valid_table_name?(table_name) do
      do_fetch_table_data(table_name, connection)
    else
      {:error, :table_not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table data: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp do_fetch_table_data(table_name, connection) do
    repo = PhoenixKit.RepoHelper.repo()

    case table_exists?(repo, table_name) do
      {:ok, true} ->
        fetch_table_rows(repo, table_name, connection.max_records_per_request || 10_000)

      {:ok, false} ->
        {:error, :table_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_table_name?(table_name), do: Validators.valid_table_name?(table_name)

  defp table_exists?(repo, table_name) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = $1
    )
    """

    case SQL.query(repo, query, [table_name]) do
      {:ok, %{rows: [[exists]]}} -> {:ok, exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_table_rows(repo, table_name, limit) do
    query = "SELECT * FROM #{quote_ident(table_name)} LIMIT $1"

    case SQL.query(repo, query, [limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, rows_to_maps(rows, columns)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rows_to_maps(rows, columns) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, serialize_value(val)} end)
    end)
  end

  # Serialize values for JSON transport
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(%Time{} = t), do: Time.to_iso8601(t)
  defp serialize_value(%Decimal{} = d), do: Decimal.to_string(d)

  defp serialize_value(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      %{"__phoenix_kit_binary__" => Base.encode64(binary)}
    end
  end

  defp serialize_value(val), do: val

  defp validate_schema_params(params), do: Validators.validate_schema(params)
  defp validate_records_params(params), do: Validators.validate_records(params)

  defp get_table_schema(table_name) do
    if valid_table_name?(table_name) do
      do_get_table_schema(table_name)
    else
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp do_get_table_schema(table_name) do
    repo = PhoenixKit.RepoHelper.repo()

    query = """
    SELECT
      column_name,
      data_type,
      is_nullable,
      column_default,
      character_maximum_length
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = $1
    ORDER BY ordinal_position
    """

    case SQL.query(repo, query, [table_name]) do
      {:ok, %{rows: [], columns: _columns}} ->
        {:error, :not_found}

      {:ok, %{rows: rows, columns: columns}} ->
        schema_columns = Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)

        # primary_key is additive: receivers that predate it ignore it, and
        # without it a table created from this schema would have no key.
        {:ok,
         %{
           table_name: table_name,
           columns: schema_columns,
           primary_key: table_primary_key(table_name)
         }}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp get_table_records(table_name, limit, offset, filter_opts) do
    if valid_table_name?(table_name) do
      do_get_table_records(table_name, limit, offset, filter_opts)
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table records: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp do_get_table_records(table_name, limit, offset, filter_opts) do
    repo = PhoenixKit.RepoHelper.repo()

    case table_exists?(repo, table_name) do
      {:ok, true} ->
        fetch_filtered_records(repo, table_name, limit, offset, filter_opts)

      {:ok, false} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_filtered_records(repo, table_name, limit, offset, filter_opts) do
    pk_col = resolve_pk_column(table_name)
    {where_clause, params, next_param} = build_where_clause(filter_opts, quote_ident(pk_col))

    data_query =
      "SELECT * FROM #{quote_ident(table_name)}#{where_clause} ORDER BY #{quote_ident(pk_col)} LIMIT $#{next_param} OFFSET $#{next_param + 1}"

    all_params = params ++ [limit, offset]

    case SQL.query(repo, data_query, all_params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, serialize_rows(rows, columns)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # PhoenixKit.RepoHelper.get_pk_column/1 falls back to "id" for any
  # table it doesn't recognise as an Ecto schema. That's wrong for
  # phoenix_kit's UUIDv7-PK tables (and any other UUID-PK table). Query
  # Postgres directly via SchemaInspector.get_primary_key/2 — works for
  # any real table.
  defp table_primary_key(table_name) do
    case SchemaInspector.get_primary_key(table_name) do
      {:ok, pk_cols} -> pk_cols
      {:error, _} -> []
    end
  end

  defp resolve_pk_column(table_name) do
    case SchemaInspector.get_primary_key(table_name) do
      {:ok, [pk | _]} when is_binary(pk) -> pk
      _ -> "id"
    end
  end

  defp serialize_rows(rows, columns) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Enum.map(fn {col, val} -> {col, serialize_value(val)} end)
      |> Map.new()
    end)
  end

  # Identifiers are always quoted: unquoted, Postgres folds case, so a
  # request for "Users" would read "users" even when only the former passed
  # the connection's table checks, and a table named like a keyword
  # ("order", "user") would not parse. `""` escapes a quote inside a name.
  defp quote_ident(name), do: ~s["#{String.replace(name, ~s["], ~s[""])}"]

  # `pk_col` arrives quoted.
  defp build_where_clause(opts, pk_col) do
    ids = Keyword.get(opts, :ids)
    id_start = Keyword.get(opts, :id_start)
    id_end = Keyword.get(opts, :id_end)

    cond do
      is_list(ids) and ids != [] ->
        {" WHERE #{pk_col} = ANY($1)", [ids], 2}

      not is_nil(id_start) and not is_nil(id_end) ->
        {" WHERE #{pk_col} >= $1 AND #{pk_col} <= $2", [id_start, id_end], 3}

      not is_nil(id_start) ->
        {" WHERE #{pk_col} >= $1", [id_start], 2}

      not is_nil(id_end) ->
        {" WHERE #{pk_col} <= $1", [id_end], 2}

      true ->
        {"", [], 1}
    end
  end
end
