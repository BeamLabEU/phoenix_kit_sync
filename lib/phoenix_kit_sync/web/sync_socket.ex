defmodule PhoenixKitSync.Web.SyncSocket do
  @moduledoc """
  Socket for DB Sync module.

  This socket accepts external WebSocket connections from sender sites
  that want to connect using a connection code.

  ## Authentication

  Senders connect by providing:
  - `code` - The 8-character connection code from the receiver

  The socket validates the code and associates the connection with
  the receiver's session.

  ## Example Connection

      // On sender site (using websockex or JS WebSocket)
      const socket = new WebSocket("wss://receiver-site.com/sync/websocket?code=ABC12345")
  """

  use Phoenix.Socket
  require Logger

  alias PhoenixKitSync

  channel "transfer:*", PhoenixKitSync.Web.SyncChannel

  @impl true
  def connect(%{"code" => code}, socket, _connect_info) when is_binary(code) do
    # Check if DB Sync is enabled
    if PhoenixKitSync.enabled?() do
      # Validate the connection code
      case PhoenixKitSync.validate_code(code) do
        # Only a `:send` session serves rows (see SocketPlug).
        {:ok, %{direction: direction}} when direction != :send ->
          Logger.warning("Sync: Session code of a session that does not send")
          {:error, :invalid_code}

        {:ok, session} ->
          Logger.info("Sync: Sender connected with a session code")

          socket =
            socket
            |> assign(:session_code, code)
            |> assign(:session, session)
            |> assign(:direction, :sender)

          {:ok, socket}

        {:error, :invalid_code} ->
          Logger.warning("Sync: Invalid session code attempt")
          {:error, :invalid_code}

        {:error, :already_used} ->
          Logger.warning("Sync: Session code already used")
          {:error, :already_used}
      end
    else
      Logger.warning("Sync: Connection attempt but module is disabled")
      {:error, :module_disabled}
    end
  end

  def connect(_params, _socket, _connect_info) do
    Logger.warning("Sync: Connection attempt without code")
    {:error, :missing_code}
  end

  @impl true
  def id(socket), do: "sync:#{socket.assigns.session_code}"
end
