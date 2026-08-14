defmodule PhoenixKitSync.Web.SocketPlugTest do
  use PhoenixKitSync.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Web.SocketPlug

  defp upgrade_request(query_string) do
    conn(:get, "/sync/websocket?" <> query_string)
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("connection", "upgrade")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> Map.put(:request_path, "/sync/websocket")
  end

  defp create_active_sender(attrs \\ %{}) do
    defaults = %{
      "name" => "Plug Test #{System.unique_integer([:positive])}",
      "direction" => "sender",
      "site_url" =>
        Map.get(attrs, "site_url") ||
          "https://plug-test-#{System.unique_integer([:positive])}.example.com",
      "approval_mode" => "auto_approve"
    }

    {:ok, conn, token} = Connections.create_connection(Map.merge(defaults, attrs))
    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    {active, token}
  end

  describe "non-WebSocket requests" do
    test "rejects with 400 when missing Upgrade header" do
      result =
        conn(:get, "/sync/websocket?token=anything")
        |> Map.put(:request_path, "/sync/websocket")
        |> SocketPlug.call([])

      assert result.status == 400
      assert result.resp_body =~ "WebSocket"
    end
  end

  describe "module disabled" do
    test "rejects with 403 when sync module is disabled" do
      PhoenixKitSync.disable_system()

      result =
        upgrade_request("token=anything")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Module disabled"

      PhoenixKitSync.enable_system()
    end
  end

  describe "missing authentication" do
    setup do
      PhoenixKitSync.enable_system()
      :ok
    end

    test "rejects with 403 when neither code nor token is provided" do
      result =
        upgrade_request("")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Missing authentication"
    end
  end

  describe "session code authentication (ephemeral)" do
    setup do
      PhoenixKitSync.enable_system()
      :ok
    end

    test "rejects invalid code with 403" do
      result =
        upgrade_request("code=NOTREAL1")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Invalid"
    end

    # Valid-code path requires a real session in SessionStore. We can't
    # fully complete the WebSocket upgrade in a Plug.Test conn (no
    # socket adapter); the upgrade raises `WebSockAdapter.UpgradeError`.
    # That error is itself proof the auth gate passed — we made it
    # past the 403 branches into validate_code_and_upgrade's upgrade
    # call.
    test "accepts valid session code (validation passes the auth gate)" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      assert_raise WebSockAdapter.UpgradeError, fn ->
        upgrade_request("code=#{session.code}")
        |> SocketPlug.call([])
      end
    end
  end

  describe "connection token authentication (permanent)" do
    setup do
      PhoenixKitSync.enable_system()
      :ok
    end

    test "rejects invalid token with 403" do
      result =
        upgrade_request("token=not-a-real-token")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Invalid token"
    end

    test "rejects token for suspended connection with 403" do
      {connection, token} = create_active_sender()
      Connections.suspend_connection(connection, PhoenixKitSync.TestActor.uuid())

      result =
        upgrade_request("token=#{token}")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "not active"
    end

    test "rejects token outside allowed hours" do
      # `allowed_hours_*` are integer hours in the schema. Pick a
      # 1-hour window that's definitely not the current UTC hour.
      {connection, token} = create_active_sender()
      current_hour = DateTime.utc_now().hour
      # Always-distant window: shift current_hour by 12 to land on the
      # opposite side of the clock, then pin a 1-hour band.
      start_hour = rem(current_hour + 12, 24)
      end_hour = rem(start_hour + 1, 24)

      {:ok, _} =
        Connections.update_connection(connection, %{
          "allowed_hours_start" => start_hour,
          "allowed_hours_end" => end_hour
        })

      result =
        upgrade_request("token=#{token}")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Outside allowed hours"
    end

    test "rejects when download limit reached" do
      {connection, token} = create_active_sender()

      Connections.update_connection(connection, %{
        "max_downloads" => 1,
        "downloads_used" => 1
      })

      result =
        upgrade_request("token=#{token}")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "limit"
    end

    test "rejects token without password when download_password is set" do
      {connection, token} = create_active_sender()
      Connections.update_connection(connection, %{"download_password" => "shibboleth"})

      result =
        upgrade_request("token=#{token}")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Invalid password"
    end

    test "rejects token with wrong password" do
      {connection, token} = create_active_sender()
      Connections.update_connection(connection, %{"download_password" => "shibboleth"})

      result =
        upgrade_request("token=#{token}&password=wrong")
        |> SocketPlug.call([])

      assert result.status == 403
      assert result.resp_body =~ "Invalid password"
    end
  end
end
