defmodule PhoenixKitSync.Web.ConnectionsLive.Status do
  @moduledoc """
  Status-resolution and connection-verification helpers for the Connections
  LiveView.

  The LiveView spawns linked tasks that call into this module when it mounts
  or reloads the connections list:

  - `fetch_sender_statuses/1` — for each active `receiver` connection, asks the
    remote site's `/sync/api/status` endpoint whether this site's paired
    sender is still reachable, sending `{:sender_status_fetched, uuid, status}`
    back to the LV once the HTTP round-trip completes.
  - `verify_receiver_connections/1` — for each `sender` connection we've
    previously handed off credentials to, asks the remote receiver whether
    the connection record still exists; sends `{:receiver_connection_severed,
    uuid}` when the remote says "no such connection," which the LV turns
    into a local suspend.

  Both are display-only — the tasks die with the LiveView via
  `Task.start_link/1`.

  The LV owns the `handle_info` clauses that process the results.
  """

  alias PhoenixKitSync.ConnectionNotifier

  require Logger

  @doc """
  For each active receiver connection, fetches the paired sender's status
  from the remote site in a linked task. Result is sent back to the caller as
  `{:sender_status_fetched, connection_uuid, status_string}`.

  Status strings: `"active"`, `"suspended"`, `"revoked"`, `"pending"` (from
  the remote), or `"offline"` / `"not_found"` / `"error"` (from failure
  modes).
  """
  @spec fetch_sender_statuses(list(), pid()) :: :ok
  def fetch_sender_statuses(receiver_connections, pid \\ self()) do
    # Only an active connection is asked about. A pending receiver row is a
    # registration nobody here has approved: its `site_url` is whatever the
    # request claimed, and this site makes no request to it until an admin
    # has.
    receiver_connections
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.each(fn conn ->
      Task.start_link(fn ->
        status = resolve_sender_status(conn)
        send(pid, {:sender_status_fetched, conn.uuid, status})
      end)
    end)
  end

  @doc """
  For each sender connection we've previously propagated to a remote
  receiver, verifies the connection record still exists there. Sends
  `{:receiver_connection_severed, uuid}` when the remote returns not-found;
  logs but doesn't send on other failure modes (offline / transport error
  are treated as transient).
  """
  @spec verify_receiver_connections(list(), pid()) :: :ok
  def verify_receiver_connections(sender_connections, pid \\ self()) do
    Enum.each(sender_connections, fn conn ->
      if should_verify_connection?(conn) do
        verify_single_connection(conn, pid)
      end
    end)
  end

  defp resolve_sender_status(conn) do
    case ConnectionNotifier.query_sender_status(conn) do
      {:ok, status} when is_binary(status) -> status
      {:ok, :offline} -> "offline"
      {:ok, :not_found} -> "not_found"
      {:error, _reason} -> "error"
    end
  end

  # Only verify connections we've actually propagated to a remote site.
  # Connections that never got their initial `register_connection` HTTP call
  # have no remote counterpart to verify against — checking them would
  # always return not_found and trigger a spurious suspend.
  defp should_verify_connection?(conn) do
    notification_success =
      get_in(conn.metadata || %{}, ["remote_notification", "notification_success"])

    conn.status in ["active", "pending", "suspended"] && notification_success == true
  end

  defp verify_single_connection(conn, pid) do
    Task.start_link(fn ->
      handle_verification_result(ConnectionNotifier.verify_connection(conn), conn.uuid, pid)
    end)
  end

  defp handle_verification_result({:ok, :not_found}, conn_uuid, pid) do
    Logger.warning("[Sync.Connections] Verify returned not_found for connection #{conn_uuid}")

    send(pid, {:receiver_connection_severed, conn_uuid})
  end

  defp handle_verification_result({:ok, :offline}, conn_uuid, _pid) do
    Logger.debug("[Sync.Connections] Remote site offline during verify | uuid=#{conn_uuid}")
  end

  defp handle_verification_result({:error, reason}, conn_uuid, _pid) do
    Logger.warning(
      "[Sync.Connections] Verify failed for connection #{conn_uuid} | error=#{inspect(reason)}"
    )

    # Don't trigger severed on errors — could be transient network issue or hot reload
  end

  defp handle_verification_result(_result, _conn_uuid, _pid), do: :ok
end
