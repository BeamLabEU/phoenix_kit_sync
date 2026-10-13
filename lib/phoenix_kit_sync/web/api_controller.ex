defmodule PhoenixKitSync.Web.ApiController do
  @moduledoc """
  API controller for Sync cross-site operations.

  The remote site is not trusted: every action treats its parameters as
  data, and the actions that read tables authorize each request through
  `PhoenixKitSync.Connections.authorize_request/3`, the same function the
  WebSocket path calls.

  ## Endpoints

  - `POST /{prefix}/sync/api/register-connection` - Register an incoming
    connection (unauthenticated; the incoming mode decides what it becomes)
  - `POST /{prefix}/sync/api/update-status` - The sender reports a status
    for this site's receiver connection
  - `POST /{prefix}/sync/api/delete-connection`, `verify-connection`,
    `get-connection-status` - Connection housekeeping between the two sites
  - `POST /{prefix}/sync/api/list-tables`, `pull-data`, `table-schema`,
    `table-records` - What a receiver reads from this site's sender
    connection
  - `GET /{prefix}/sync/api/status` - Whether the module accepts connections
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitSync
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.ExtensionTypes
  alias PhoenixKitSync.PullCursor
  alias PhoenixKitSync.PullFilter
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

  - 200 OK - Connection registered; `connection_status` is `"active"` under
    the `auto_accept` mode or after a matching password, and `"pending"`
    under `require_approval`, where an admin of this site approves it
  - 400 Bad Request - Missing required fields
  - 401 Unauthorized - Invalid password
  - 403 Forbidden - Incoming connections are denied
  - 409 Conflict - Connection already exists for this site
  - 429 Too Many Requests - Too many registrations are awaiting approval
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def register_connection(conn, params) do
    remote_ip = client_ip(conn)

    Logger.info(
      "[Sync.API] register_connection called " <>
        "| sender_url=#{inspect(params["sender_url"])} " <>
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
            "| sender_url=#{inspect(params["sender_url"])} " <>
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
            "| sender_url=#{inspect(params["sender_url"])}"
        )

        render_json_error(conn, 401, :invalid_password)

      {:error, :password_required} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: password required " <>
            "| sender_url=#{inspect(params["sender_url"])}"
        )

        render_json_error(conn, 401, :password_required)

      {:error, :connection_exists} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: already exists " <>
            "| sender_url=#{inspect(params["sender_url"])}"
        )

        render_json_error(conn, 409, :connection_exists)

      {:error, :too_many_pending} ->
        Logger.warning(
          "[Sync.API] register_connection rejected: too many registrations await approval " <>
            "| remote_ip=#{remote_ip}"
        )

        render_json_error(conn, 429, :too_many_pending)

      {:error, {:changeset_error, _changeset}} ->
        render_json_error(conn, 400, :invalid_registration)
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
  Mirrors a status the sender reports onto this site's receiver connection.

  Called when the sender suspends, reactivates, or revokes its connection.
  Only the `"receiver"` row for that sender is looked up, and
  `Connections.apply_remote_status/2` decides whether the change is one a
  peer may make: it can suspend or revoke an active connection and lift a
  suspension it reported itself. It can never activate a pending, revoked
  or locally suspended connection, and never touches a `"sender"` row,
  whose status decides what the peer may read.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `status` (required) - The new status ("active", "suspended", "revoked")

  ## Responses

  - 200 OK - Status updated, or already that status
  - 404 Not Found - No receiver connection for that sender and token
  - 409 Conflict - The remote site may not make this change
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def update_status(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_status_params(params),
         {:ok, connection} <-
           find_receiver_connection(validated.sender_url, validated.auth_token_hash),
         {:ok, updated} <- Connections.apply_remote_status(connection, validated.status) do
      # PubSub broadcast handled by Connections.apply_remote_status

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

      {:error, :status_change_not_allowed} ->
        render_json_error(conn, 409, :status_change_not_allowed, %{
          error_code: "status_change_not_allowed"
        })

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
  This allows receivers to sync their status with the sender. It only
  reads: no status changes here, a pending connection included.

  Expected JSON body:
  - `receiver_url` (required) - URL of the receiver site requesting status;
    logged, not matched (the token hash names the connection)
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
      # A read: the answer changes nothing. A pending connection stays
      # pending until an admin of this site approves it, whoever asks.
      Logger.info(
        "Sync API: Found sender connection #{connection.uuid} with status '#{connection.status}'"
      )

      conn
      |> put_status(200)
      |> json(%{success: true, status: connection.status, name: connection.name})
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

  # What Connections.authorize_request/3 refuses with. The peer gets the
  # reason as text and as "error_code".
  @authorization_errors [
    :unauthorized,
    :connection_not_active,
    :connection_expired,
    :download_limit_reached,
    :record_limit_reached,
    :ip_not_allowed,
    :outside_allowed_hours,
    :invalid_password
  ]

  @doc """
  Lists available tables for sync.

  Called by receiver to get a list of tables that can be synced from this sender.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `password` (optional) - The connection's download password, when it has one
  - `include_checksums` (optional) - `false` leaves the per-table content
    checksum out (`"checksum": null`), sparing the sender an md5 over every
    table; anything else includes it

  ## Responses

  - 200 OK - Returns list of tables with row counts and sizes
  - 401 Unauthorized - Invalid auth token
  - 403 Forbidden - The connection may not be used now (`error_code` says
    why: not active, expired, a limit reached, IP, hours, password)
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def list_tables(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_list_tables_params(params),
         {:ok, connection} <- authorize_sender(conn, validated.auth_token_hash, params) do
      # Authorization: even with a valid token, only return tables this
      # particular connection is allowed to see (excluded_tables blocklist
      # AND, if set, the allowed_tables allowlist). Without this filter a
      # leaked token would grant blanket DB access regardless of the
      # connection's intended scope.
      tables = get_syncable_tables(connection, include_checksums?(params))

      Connections.touch_connected(connection)

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

      {:error, reason} when reason in @authorization_errors ->
        render_authorization_error(conn, reason)
    end
  end

  @filter_errors [
    :invalid_filter,
    :unsupported_key_type,
    :filter_needs_single_key,
    :invalid_cursor,
    :no_primary_key
  ]

  @doc """
  Pulls data for a specific table.

  Called by receiver to fetch table data during sync.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `table_name` (required) - Name of the table to pull
  - `conflict_strategy` (optional) - How to handle conflicts (skip, overwrite, merge)
  - `ids` (optional) - Up to 1000 key values to pull, or
  - `id_start` / `id_end` (optional) - An integer key range; either bound may be left out
  - `after` (optional) - The `next_after` of the previous answer: only the
    rows after that key are sent (`PhoenixKitSync.PullCursor`)
  - `cursor` (optional) - The `cursor` of the previous answer. With it the
    page counts as part of the download that produced it rather than as a
    new one
  - `paged` (optional) - `true` from a receiver that follows `next_after`
  - `password` (optional) - The connection's download password, when it has one

  The filter needs a single-column key and is compared in the key's own
  type (`PhoenixKitSync.PullFilter`). It is read only after the token and
  the table pass their checks.

  ## Responses

  - 200 OK - Returns table data in key order; `"filtered": true` when a
    filter was applied. `"has_more"` says whether rows are left past this
    answer, which stops at the connection's `max_records_per_request`.
    When they are, `"truncated": true` is set as well (the key is left out
    otherwise; it is what a receiver without cursors reads), and
    `"next_after"` and `"cursor"` continue the pull. A key whose type has no
    cursor gets `"truncated"` and `"unsupported_key_type"`, the type's name.
  - 400 Bad Request - Missing fields, an invalid filter or cursor, a key
    type that takes no filter, or a table without a primary key
    (`"error_code": "no_primary_key"`: without a key its rows have no order
    to page in)
  - 401 Unauthorized - Invalid auth token
  - 403 Forbidden - The connection may not be used now, or not for this table
  - 404 Not Found - Table not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def pull_data(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_pull_data_params(params),
         {:ok, after_values} <- PullCursor.from_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         continuation =
           continuation?(conn, connection, validated.table_name, after_values, params),
         :ok <- authorize(conn, connection, params, continuation: continuation),
         :ok <- check_table_allowed(connection, validated.table_name),
         {:ok, filter} <- PullFilter.from_params(params),
         {:ok, reservation} <-
           Connections.reserve_transfer(connection, %{
             downloads: if(continuation, do: 0, else: 1),
             records: request_limit(connection)
           }),
         {:ok, page} <-
           reserved(
             reservation,
             fetch_table_data(validated.table_name, reservation.records, filter, after_values)
           ) do
      record_count = length(page.data)

      Connections.settle_transfer(reservation, record_count)

      record_send(connection, validated, record_count, page, params["paged"] == true)

      Logger.info("Sending #{record_count} records for table #{validated.table_name}")

      conn
      |> put_status(200)
      |> json(pull_response(conn, connection, validated.table_name, page, filter))
    else
      {:error, filter_error} when filter_error in @filter_errors ->
        render_filter_error(conn, filter_error)

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

      {:error, reason} when reason in @authorization_errors ->
        render_authorization_error(conn, reason)

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

  # "filtered" tells the receiver the filter was applied: a sender that
  # predates filters ignores them and leaves this out, and the receiver
  # then refuses to import a whole table it asked a few rows of.
  # "truncated" says the answer stopped with more rows left. It is only
  # added, never false: a receiver from before it reads "data" alone and
  # carries on as it always did. "next_after" and "cursor" are what a
  # receiver that pages sends back for the rest.
  defp pull_response(conn, connection, table_name, page, filter) do
    response = %{success: true, table: table_name, data: page.data, has_more: page.more?}
    response = if filter, do: Map.put(response, :filtered, true), else: response
    response = if page.more?, do: Map.put(response, :truncated, true), else: response

    case page do
      %{more?: true, next_after: %{} = next_after} ->
        Map.merge(response, %{
          next_after: next_after,
          cursor: sign_cursor(conn, connection, table_name, next_after)
        })

      # Cut with nothing to continue from because of the key's type: the
      # type is named, so the receiving admin reads why and what to do.
      %{more?: true, key_without_cursor: [_ | _] = types} ->
        Map.put(response, :unsupported_key_type, Enum.join(types, ", "))

      _no_cursor ->
        response
    end
  end

  # The cursor proves a request continues a download this site already
  # counted: it is signed with the endpoint's secret for one connection, one
  # table and one key, so a peer cannot mint one to read a table without
  # spending a download. It is free only for the exact position it was
  # signed for (an earlier or later `after` under it is a new download) and
  # only for ten minutes, which is the time a receiver has to import one
  # page before asking for the next. Within that window the same page can
  # be asked for again without a download being counted; its rows are
  # counted in `records_downloaded` every time, and the record limit and
  # every other restriction apply to it as to any request.
  @cursor_salt "phoenix_kit_sync pull cursor"
  @cursor_max_age 600

  defp sign_cursor(conn, connection, table_name, next_after) do
    Phoenix.Token.sign(conn, @cursor_salt, cursor_claim(connection, table_name, next_after))
  end

  # The answer is read under a reservation (Connections.reserve_transfer/2):
  # one that fails sent no rows, so it gives the download and the page back.
  defp reserved(_reservation, {:ok, _} = result), do: result

  defp reserved(reservation, error) do
    Connections.cancel_transfer(reservation)
    error
  end

  defp continuation?(_conn, _connection, _table_name, nil, _params), do: false

  defp continuation?(conn, connection, table_name, after_values, params) do
    with cursor when is_binary(cursor) <- params["cursor"],
         {:ok, claim} <-
           Phoenix.Token.verify(conn, @cursor_salt, cursor, max_age: @cursor_max_age) do
      claim == cursor_claim(connection, table_name, after_values)
    else
      _ -> false
    end
  end

  defp cursor_claim(connection, table_name, after_values),
    do: %{c: connection.uuid, t: table_name, a: after_values}

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
         {:ok, connection} <- authorize_sender(conn, validated.auth_token_hash, params),
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

      {:error, reason} when reason in @authorization_errors ->
        render_authorization_error(conn, reason)

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

  The filter is pull-data's (`PhoenixKitSync.PullFilter`).

  Every answer counts as one download and its rows as records, against
  `max_downloads` and `max_records_total` like a pull's.

  Returns:
  - 200 OK with records, ordered by the key (fewer than `limit` when less
    is left of the record limit)
  - 400 Bad Request - An invalid filter, a key type that takes no filter,
    or a table without a single-column key (`error_code` says which)
  - 401 Unauthorized
  - 404 Not Found
  """
  def table_records(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_records_params(params),
         {:ok, connection} <- authorize_sender(conn, validated.auth_token_hash, params),
         :ok <- check_table_allowed(connection, validated.table_name),
         {:ok, filter} <- PullFilter.from_params(params),
         # A page of rows is a page of rows whichever action serves it: it
         # is a download and its rows count, or paging through this action
         # would read a table past both limits.
         {:ok, reservation} <-
           Connections.reserve_transfer(connection, %{downloads: 1, records: validated.limit}) do
      table_name = validated.table_name
      offset = validated.offset

      case reserved(
             reservation,
             get_table_records(table_name, reservation.records, offset, filter)
           ) do
        {:ok, records} ->
          Connections.settle_transfer(reservation, length(records))

          conn
          |> put_status(200)
          |> json(%{success: true, records: records})

        {:error, filter_error} when filter_error in @filter_errors ->
          render_filter_error(conn, filter_error)

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{success: false, error: "Table not found"})

        {:error, reason} ->
          Logger.error("Failed to get records", %{reason: inspect(reason)})

          conn
          |> put_status(500)
          |> json(%{success: false, error: "Failed to get records"})
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

      {:error, reason} when reason in @authorization_errors ->
        render_authorization_error(conn, reason)

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields: #{Enum.join(fields, ", ")}"})

      {:error, :table_not_allowed} ->
        render_json_error(conn, 403, :table_not_allowed)

      {:error, :invalid_filter} ->
        render_filter_error(conn, :invalid_filter)
    end
  end

  # A filter or cursor refusal carries "error_code" for the receiver to act
  # on; the "error" text is for people.
  defp render_filter_error(conn, code) do
    text =
      case code do
        :invalid_filter -> "Invalid filter"
        :unsupported_key_type -> "Filter not supported for this key type"
        :filter_needs_single_key -> "Filter needs a single-column primary key"
        :invalid_cursor -> "Invalid cursor"
        :no_primary_key -> "Table has no primary key"
      end

    conn
    |> put_status(400)
    |> json(%{success: false, error: text, error_code: Atom.to_string(code)})
  end

  defp render_authorization_error(conn, reason) do
    render_json_error(conn, 403, reason, %{error_code: Atom.to_string(reason)})
  end

  # --- Private Functions ---

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

  # A status report comes from the sender, so it names this site's receiver
  # row for that sender. A sender row is never found here: its status is
  # this site's decision about what the peer may read.
  defp find_receiver_connection(sender_url, auth_token_hash) do
    case Connections.find_by_site_url_and_hash(sender_url, auth_token_hash, "receiver") do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
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

  # The duplicate check, the pending cap and the insert are one step
  # (Connections.register_incoming/2): registrations arriving together
  # cannot each pass a check the others are about to make false.
  defp create_incoming_connection(params, conn) do
    initial_status = initial_incoming_status()
    remote_ip = client_ip(conn)
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
        "user_agent" => String.slice(user_agent, 0, 255)
      }
    }

    Logger.info(
      "[Sync.API] Creating incoming connection " <>
        "| sender_url=#{params.sender_url} " <>
        "| connection_name=#{inspect(params.connection_name)} " <>
        "| initial_status=#{initial_status} " <>
        "| remote_ip=#{remote_ip}"
    )

    case Connections.register_incoming(attrs, max_pending: max_pending_incoming()) do
      {:ok, connection} ->
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
           status: connection.status,
           message: registered_message(connection.status),
           connection_uuid: connection.uuid
         }}

      {:error, :connection_exists} ->
        Logger.info(
          "[Sync.API] Incoming connection already exists | sender_url=#{params.sender_url}"
        )

        {:error, :connection_exists}

      {:error, :too_many_pending} ->
        {:error, :too_many_pending}

      {:error, changeset} ->
        Logger.warning(
          "[Sync.API] Failed to create incoming connection " <>
            "| sender_url=#{params.sender_url} " <>
            "| errors=#{inspect(changeset.errors)}"
        )

        {:error, {:changeset_error, changeset}}
    end
  end

  # The request is unauthenticated unless the mode asks for a password, so
  # only two modes may activate what it creates: `auto_accept`, which says
  # so, and `require_password`, which validate_password/1 has checked by
  # now. Under `require_approval` the row waits for an admin of this site.
  defp initial_incoming_status do
    case PhoenixKitSync.get_incoming_mode() do
      mode when mode in ["auto_accept", "require_password"] -> "active"
      _require_approval -> "pending"
    end
  end

  # Anyone can post a registration, and each one waiting for approval is a
  # row an admin has to look at. Past this many, new ones are refused until
  # some are approved or deleted.
  @default_max_pending_incoming 50

  defp max_pending_incoming do
    Application.get_env(:phoenix_kit_sync, :max_pending_incoming, @default_max_pending_incoming)
  end

  defp registered_message("active"), do: "Connection registered and activated"
  defp registered_message(_pending), do: "Connection registered, awaiting approval"

  # The address the request came from, by core's rule: `conn.remote_ip`,
  # and a forwarded header only when that is a proxy on this box or network
  # (the last hop, which the proxy appended). A client-supplied
  # `X-Forwarded-For` first hop is never believed, so it cannot name a
  # whitelisted address.
  defp client_ip(conn), do: IpAddress.client_address(conn) || "unknown"

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

  # The one authorization of the table-reading actions: the row found by
  # the token hash, checked by Connections.authorize_request/3 as it is in
  # the database now.
  defp authorize_sender(conn, auth_token_hash, params) do
    with {:ok, connection} <- find_sender_by_hash(auth_token_hash),
         :ok <- authorize(conn, connection, params, []) do
      {:ok, connection}
    end
  end

  defp authorize(conn, connection, params, opts) do
    Connections.authorize_request(
      connection,
      client_ip(conn),
      Keyword.put(opts, :password, string_or_nil(params["password"]))
    )
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

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

  # A receiver that does not show checksums says so and spares this site
  # an md5 over every table; one that says nothing gets them.
  defp include_checksums?(params), do: params["include_checksums"] != false

  defp get_syncable_tables(connection, include_checksums?) do
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
        # Filtered before the counts and checksums, so a table the
        # connection may not see is never read at all.
        for [name, size_bytes] <- rows,
            PhoenixKitSync.Connection.table_allowed?(connection, name) do
          build_table_info(repo, name, size_bytes, fk_map, include_checksums?)
        end

      {:error, _} ->
        []
    end
  rescue
    e ->
      Logger.error("[Sync.API] get_syncable_tables crashed: #{inspect(e)}")
      []
  end

  defp build_table_info(repo, name, size_bytes, fk_map, include_checksums?) do
    row_count = get_actual_row_count(repo, name)

    %{
      "name" => name,
      "row_count" => row_count,
      "size_bytes" => size_bytes,
      "checksum" => if(include_checksums?, do: table_checksum(name)),
      "depends_on" => Map.get(fk_map, name, [])
    }
  end

  defp table_checksum(name) do
    case SchemaInspector.get_table_checksum(name) do
      {:ok, cs} when is_binary(cs) -> cs
      _ -> nil
    end
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

  defp fetch_table_data(table_name, limit, filter, after_values) do
    if valid_table_name?(table_name) do
      do_fetch_table_data(table_name, limit, filter, after_values)
    else
      {:error, :table_not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table data: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  # One row past the limit is fetched to tell a table that fits in one
  # answer from one that was cut.
  defp do_fetch_table_data(table_name, limit, filter, after_values) do
    repo = PhoenixKit.RepoHelper.repo()

    with :ok <- require_table(repo, table_name),
         {:ok, key, arrays} <- table_key(table_name),
         {:ok, filter_where, filter_binds} <- filter_where(key, filter),
         {:ok, after_where, after_binds} <-
           after_where(key, after_values, length(filter_binds)),
         {:ok, rows, columns} <-
           fetch_page(
             repo,
             table_name,
             key,
             [filter_where, after_where],
             filter_binds ++ after_binds,
             limit + 1
           ) do
      kept = Enum.take(rows, limit)
      more? = length(rows) > limit

      {next_after, without_cursor} =
        if more?, do: next_after(key, kept, columns), else: {nil, []}

      {:ok,
       %{
         data: serialize_rows(kept, columns, arrays),
         more?: more?,
         next_after: next_after,
         key_without_cursor: PullCursor.unsupported_types(key) ++ without_cursor
       }}
    end
  end

  defp require_table(repo, table_name) do
    case table_exists?(repo, table_name) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :table_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The primary key as `{column, type}` pairs. Rows are read in its order,
  # which is what makes a page repeatable and a cursor possible; a table
  # (or view) without one has no such order, so it is refused rather than
  # paged in whatever order the heap gives. The third element names the
  # element type of each array column, which its values are serialized by.
  defp table_key(table_name) do
    case table_primary_key(table_name) do
      [] ->
        {:error, :no_primary_key}

      pk_cols ->
        columns =
          case SchemaInspector.get_schema(table_name) do
            {:ok, %{columns: columns}} -> columns
            _ -> []
          end

        types = Map.new(columns, &{&1.name, &1.type})

        arrays =
          for %{type: "ARRAY"} = col <- columns, into: %{}, do: {col.name, col.element_type}

        {:ok, Enum.map(pk_cols, &{&1, Map.get(types, &1)}), arrays}
    end
  end

  defp filter_where(_key, nil), do: {:ok, nil, []}

  # A filter needs a single-column key; PullFilter compares in its type.
  defp filter_where([{pk, type}], filter),
    do: PullFilter.where(filter, quote_ident(pk), type)

  defp filter_where(_composite_key, _filter), do: {:error, :filter_needs_single_key}

  defp after_where(_key, nil, _offset), do: {:ok, nil, []}

  defp after_where(key, after_values, offset) do
    case PullCursor.where(key, after_values, offset, &quote_ident/1) do
      {:ok, where, binds} -> {:ok, where, binds}
      # A key with no cursor never answered a "next_after" to send back.
      {:error, :unsupported_key_type} -> {:error, :invalid_cursor}
      {:error, :invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp fetch_page(repo, table_name, key, conditions, binds, limit) do
    where =
      case Enum.reject(conditions, &is_nil/1) do
        [] -> ""
        conditions -> " WHERE " <> Enum.join(conditions, " AND ")
      end

    order = Enum.map_join(key, ", ", fn {col, _type} -> quote_ident(col) end)

    query =
      "SELECT * FROM #{quote_ident(table_name)}#{where} ORDER BY #{order} LIMIT $#{length(binds) + 1}"

    case SQL.query(repo, query, binds ++ [limit]) do
      {:ok, %{rows: rows, columns: columns}} -> {:ok, rows, columns}
      {:error, reason} -> {:error, reason}
    end
  end

  # The position after the last row, and the reason there is none when a
  # key value is too long to be one.
  defp next_after(_key, [], _columns), do: {nil, []}

  defp next_after(key, rows, columns) do
    last = columns |> Enum.zip(List.last(rows)) |> Map.new()

    case PullCursor.next_after(key, last) do
      {:ok, next_after} -> {next_after, []}
      {:too_long, type} -> {nil, [PullCursor.too_long_reason(type)]}
      :error -> {nil, []}
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

  # The changeset keeps max_records_per_request above zero; a value set
  # around it (nil, zero, negative) reads as the default rather than as
  # LIMIT 0 with every answer marked truncated.
  defp request_limit(%{max_records_per_request: limit}) when is_integer(limit) and limit > 0,
    do: limit

  defp request_limit(_connection), do: 10_000

  # The sender's own history, one row written once in its final state. An
  # answer that was cut for a receiver that does not page is recorded as
  # failed, with the rows it did send: that receiver did not get the whole
  # table. A receiver that pages comes back for the rest, so each of its
  # pages is a completed send.
  defp record_send(connection, validated, record_count, page, paged?) do
    attrs = %{
      direction: "send",
      connection_uuid: connection.uuid,
      table_name: validated.table_name,
      remote_site_url: connection.site_url,
      conflict_strategy: validated.conflict_strategy,
      records_transferred: record_count
    }

    if page.more? and not (paged? and is_map(page.next_after)) do
      Transfers.record_finished(attrs, {:failed, :sent_truncated})
    else
      Transfers.record_finished(attrs, :completed)
    end
  end

  # `arrays` names the element type of each array column. An array goes as
  # a JSON list whose elements are written by that type, the way
  # DataExporter writes them for the WebSocket path: a uuid element is 16
  # bytes that are no JSON string, and how they travel must not depend on
  # whether they happen to be UTF-8.
  defp serialize_rows(rows, columns, arrays) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn
        {col, list} when is_list(list) and is_map_key(arrays, col) ->
          {col, DataExporter.serialize_array(arrays[col], list)}

        {col, val} ->
          {col, serialize_value(val)}
      end)
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

  # Any other struct is a Postgrex type of its own (an interval, an inet,
  # a range), which Jason cannot encode: ExtensionTypes writes the ones
  # that travel and marks the rest.
  defp serialize_value(%_{} = struct), do: ExtensionTypes.serialize(struct)
  defp serialize_value([%Postgrex.Lexeme{} = lexeme | _]), do: ExtensionTypes.serialize(lexeme)

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

  # A base table's schema comes from SchemaInspector, which knows an array
  # column's element type; a table created from it needs that. Each column
  # also carries the information_schema names (`column_name`, `data_type`,
  # `is_nullable`, `column_default`, `character_maximum_length`) receivers
  # have always read. primary_key is additive: receivers that predate it
  # ignore it, and without it a table created from this schema would have
  # no key.
  defp do_get_table_schema(table_name) do
    case SchemaInspector.get_schema(table_name) do
      {:ok, %{columns: [_ | _] = columns, primary_key: primary_key}} ->
        {:ok,
         %{
           table_name: table_name,
           columns: Enum.map(columns, &schema_column/1),
           primary_key: primary_key
         }}

      # A view is not in pg_tables; it still has columns to show.
      _not_a_base_table ->
        get_relation_columns(table_name)
    end
  end

  defp schema_column(%{} = column) do
    %{
      "column_name" => column.name,
      "data_type" => column.type,
      "is_nullable" => if(column.nullable, do: "YES", else: "NO"),
      "column_default" => column.default,
      "character_maximum_length" => column.max_length,
      "name" => column.name,
      "type" => column.type,
      "element_type" => column.element_type,
      "nullable" => column.nullable,
      "primary_key" => column.primary_key,
      "max_length" => column.max_length
    }
  end

  defp get_relation_columns(table_name) do
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

  defp get_table_records(table_name, limit, offset, filter) do
    if valid_table_name?(table_name) do
      do_get_table_records(table_name, limit, offset, filter)
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table records: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp do_get_table_records(table_name, limit, offset, filter) do
    repo = PhoenixKit.RepoHelper.repo()

    case table_exists?(repo, table_name) do
      {:ok, true} ->
        fetch_filtered_records(repo, table_name, limit, offset, filter)

      {:ok, false} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_filtered_records(repo, table_name, limit, offset, filter) do
    with {:ok, where_and_order, params, arrays} <- records_clause(table_name, filter) do
      next = length(params) + 1

      data_query =
        "SELECT * FROM #{quote_ident(table_name)}#{where_and_order} LIMIT $#{next} OFFSET $#{next + 1}"

      run_records_query(repo, data_query, params ++ [limit, offset], arrays)
    end
  end

  # The same filter dialect as pull-data (PullFilter). Pages are ordered by
  # the key: OFFSET over an unordered read skips and repeats rows, so a
  # table without a key is refused.
  defp records_clause(table_name, filter) do
    with {:ok, key, arrays} <- table_key(table_name),
         {:ok, where, binds} <- filter_where(key, filter) do
      order = Enum.map_join(key, ", ", fn {col, _type} -> quote_ident(col) end)
      where = if where, do: " WHERE " <> where, else: ""

      {:ok, where <> " ORDER BY " <> order, binds, arrays}
    end
  end

  defp run_records_query(repo, data_query, all_params, arrays) do
    case SQL.query(repo, data_query, all_params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, serialize_rows(rows, columns, arrays)}

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

  # Identifiers are always quoted: unquoted, Postgres folds case, so a
  # request for "Users" would read "users" even when only the former passed
  # the connection's table checks, and a table named like a keyword
  # ("order", "user") would not parse. `""` escapes a quote inside a name.
  defp quote_ident(name), do: ~s["#{String.replace(name, ~s["], ~s[""])}"]
end
