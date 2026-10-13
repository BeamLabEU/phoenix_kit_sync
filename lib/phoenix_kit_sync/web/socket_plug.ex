defmodule PhoenixKitSync.Web.SocketPlug do
  @moduledoc """
  Plug for handling DB Sync WebSocket connections.

  This plug handles the HTTP upgrade to WebSocket and validates
  the connection code or auth token before handing off to SyncWebsock.

  ## Authentication Methods

  Supports two authentication methods:

  1. **Session Code** (ephemeral) - For manual one-time transfers
     - Query param: `?code=ABC12345`
     - Session is tied to LiveView process

  2. **Connection Token** (permanent) - For persistent connections
     - Query param: `?token=xyz123...`
     - Validated against database, subject to access controls

  ## Usage

  In your endpoint:

      plug PhoenixKitSync.Web.SocketPlug

  Or mount at a specific path in router (done automatically by phoenix_kit_socket macro).
  """

  @behaviour Plug
  require Logger

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitSync
  alias PhoenixKitSync.Connections

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # When used with forward in router, the path is stripped to "/"
    # When used directly in endpoint (deprecated), check if path ends with /sync/websocket
    cond do
      conn.request_path == "/" ->
        # Forwarded from router - handle the request
        handle_websocket_request(conn)

      String.ends_with?(conn.request_path, "/sync/websocket") ->
        # Direct endpoint use (deprecated) - still handle for backwards compatibility
        handle_websocket_request(conn)

      true ->
        # Not a sync websocket request - pass through
        conn
    end
  end

  defp handle_websocket_request(conn) do
    cond do
      not websocket_request?(conn) ->
        send_bad_request(conn, "Expected WebSocket upgrade")

      not PhoenixKitSync.enabled?() ->
        Logger.warning("Sync: Connection attempt but module is disabled")
        send_forbidden(conn, "Module disabled")

      true ->
        authenticate_and_upgrade(conn)
    end
  end

  defp authenticate_and_upgrade(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    code = conn.query_params["code"]
    token = conn.query_params["token"]

    cond do
      # Permanent connection token authentication
      is_binary(token) ->
        validate_token_and_upgrade(conn, token)

      # Ephemeral session code authentication
      is_binary(code) ->
        validate_code_and_upgrade(conn, code)

      # No authentication provided
      true ->
        Logger.warning("Sync: Connection attempt without code or token")
        send_forbidden(conn, "Missing authentication")
    end
  end

  defp websocket_request?(conn) do
    upgrade_header =
      Plug.Conn.get_req_header(conn, "upgrade")
      |> List.first()
      |> Kernel.||("")
      |> String.downcase()

    upgrade_header == "websocket"
  end

  # ===========================================
  # SESSION CODE AUTHENTICATION (EPHEMERAL)
  # ===========================================

  # A session code grants a read of the database, and a wrong one is
  # whatever the client typed: neither is written to the log.
  #
  # Only a `:send` session serves rows: its owner opened it to share this
  # site's data. A `:receive` session's owner asked for nothing to leave
  # the site, so its code opens no socket here.
  defp validate_code_and_upgrade(conn, code) do
    case PhoenixKitSync.validate_code(code) do
      {:ok, %{direction: direction}} when direction != :send ->
        Logger.warning("Sync: Session code of a session that does not send")
        send_forbidden(conn, "Invalid code")

      {:ok, session} ->
        Logger.info("Sync: Receiver connecting with a session code")

        # Capture connection metadata
        connection_info = extract_connection_info(conn)

        conn =
          WebSockAdapter.upgrade(
            conn,
            PhoenixKitSync.Web.SyncWebsock,
            [
              auth_type: :session,
              code: code,
              session: session,
              connection_info: connection_info
            ],
            timeout: 60_000
          )

        Plug.Conn.halt(conn)

      {:error, :invalid_code} ->
        Logger.warning("Sync: Invalid session code attempt")
        send_forbidden(conn, "Invalid code")

      {:error, :already_used} ->
        Logger.warning("Sync: Session code already used")
        send_forbidden(conn, "Code already used")
    end
  end

  # ===========================================
  # CONNECTION TOKEN AUTHENTICATION (PERMANENT)
  # ===========================================

  # Connections.validate_connection/3 runs the same authorize_request/3 the
  # REST actions use, download password included; SyncWebsock runs it again
  # for every request on the open socket.
  defp validate_token_and_upgrade(conn, token) do
    client_ip = get_remote_ip(conn)
    password = string_or_nil(conn.query_params["password"])

    case Connections.validate_connection(token, client_ip, password: password) do
      {:ok, db_connection} ->
        Logger.info("Sync: Token connection validated for #{db_connection.name}")

        # Update last connected timestamp
        Connections.touch_connected(db_connection)

        # Capture connection metadata
        connection_info = extract_connection_info(conn)

        conn =
          WebSockAdapter.upgrade(
            conn,
            PhoenixKitSync.Web.SyncWebsock,
            [
              auth_type: :connection,
              connection: db_connection,
              password: password,
              connection_info: connection_info
            ],
            timeout: 60_000
          )

        Plug.Conn.halt(conn)

      {:error, reason} ->
        handle_token_error(conn, reason, client_ip)
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp handle_token_error(conn, :invalid_token, _client_ip) do
    Logger.warning("Sync: Invalid token attempt")
    send_forbidden(conn, "Invalid token")
  end

  defp handle_token_error(conn, :connection_not_active, _client_ip) do
    Logger.warning("Sync: Token for inactive connection")
    send_forbidden(conn, "Connection not active")
  end

  defp handle_token_error(conn, :connection_expired, _client_ip) do
    Logger.warning("Sync: Token for expired connection")
    send_forbidden(conn, "Connection expired")
  end

  defp handle_token_error(conn, :download_limit_reached, _client_ip) do
    Logger.warning("Sync: Download limit reached")
    send_forbidden(conn, "Download limit reached")
  end

  defp handle_token_error(conn, :record_limit_reached, _client_ip) do
    Logger.warning("Sync: Record limit reached")
    send_forbidden(conn, "Record limit reached")
  end

  defp handle_token_error(conn, :ip_not_allowed, client_ip) do
    Logger.warning("Sync: IP not in whitelist: #{client_ip}")
    send_forbidden(conn, "IP not allowed")
  end

  defp handle_token_error(conn, :outside_allowed_hours, _client_ip) do
    Logger.warning("Sync: Connection outside allowed hours")
    send_forbidden(conn, "Outside allowed hours")
  end

  defp handle_token_error(conn, :invalid_password, _client_ip) do
    Logger.warning("Sync: Invalid download password")
    send_forbidden(conn, "Invalid password")
  end

  defp handle_token_error(conn, reason, _client_ip) do
    Logger.warning("Sync: Token connection refused (#{inspect(reason)})")
    send_forbidden(conn, "Not authorized")
  end

  defp extract_connection_info(conn) do
    remote_ip = get_remote_ip(conn)

    # Get user agent
    user_agent =
      Plug.Conn.get_req_header(conn, "user-agent")
      |> List.first()

    # Get origin/referer
    origin =
      Plug.Conn.get_req_header(conn, "origin")
      |> List.first()

    referer =
      Plug.Conn.get_req_header(conn, "referer")
      |> List.first()

    # Get host info
    host = conn.host
    port = conn.port
    scheme = if conn.scheme == :https, do: "https", else: "http"

    # Get WebSocket protocol version
    ws_version =
      Plug.Conn.get_req_header(conn, "sec-websocket-version")
      |> List.first()

    # Get accept-language for locale info
    accept_language =
      Plug.Conn.get_req_header(conn, "accept-language")
      |> List.first()

    %{
      remote_ip: remote_ip,
      user_agent: user_agent,
      origin: origin,
      referer: referer,
      host: host,
      port: port,
      scheme: scheme,
      request_path: conn.request_path,
      # Not the query string: it carries the session code, or the token and
      # the download password, and this map is shown and logged.
      websocket_version: ws_version,
      accept_language: accept_language,
      connected_at: UtilsDate.utc_now()
    }
  end

  # The address the request came from, by core's rule: `conn.remote_ip`,
  # and a forwarded header only when that is a proxy on this box or network
  # (the last hop, which the proxy appended). The first hop of
  # `X-Forwarded-For` is whatever the client sent, so it is never believed:
  # it would let any client name a whitelisted address.
  defp get_remote_ip(conn), do: IpAddress.client_address(conn) || "unknown"

  defp send_forbidden(conn, message) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(403, message)
    |> Plug.Conn.halt()
  end

  defp send_bad_request(conn, message) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, message)
    |> Plug.Conn.halt()
  end
end
