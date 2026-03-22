defmodule PhoenixKitSync.Integration.SyncWebsockTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections

  # The SyncWebsock module requires a live WebSocket connection to test its
  # handle_in/handle_info callbacks directly. Instead, we test the access
  # control logic and state management that the WebSocket handler relies on.

  describe "table access control for permanent connections" do
    test "connection with allowed_tables filters table list" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "WS Test",
          "direction" => "sender",
          "site_url" => "https://ws-test-#{System.unique_integer([:positive])}.com",
          "allowed_tables" => ["users", "posts"]
        })

      assert Connection.table_allowed?(conn, "users")
      assert Connection.table_allowed?(conn, "posts")
      refute Connection.table_allowed?(conn, "admin_settings")
    end

    test "connection with excluded_tables blocks specific tables" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "WS Exclude Test",
          "direction" => "sender",
          "site_url" => "https://ws-exclude-#{System.unique_integer([:positive])}.com",
          "excluded_tables" => ["phoenix_kit_user_tokens", "secrets"]
        })

      assert Connection.table_allowed?(conn, "users")
      refute Connection.table_allowed?(conn, "phoenix_kit_user_tokens")
      refute Connection.table_allowed?(conn, "secrets")
    end

    test "connection with empty allowed_tables allows all (except excluded)" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "WS Open Test",
          "direction" => "sender",
          "site_url" => "https://ws-open-#{System.unique_integer([:positive])}.com",
          "allowed_tables" => [],
          "excluded_tables" => ["secrets"]
        })

      assert Connection.table_allowed?(conn, "users")
      assert Connection.table_allowed?(conn, "posts")
      refute Connection.table_allowed?(conn, "secrets")
    end
  end

  describe "request limit enforcement" do
    test "connection max_records_per_request limits data transfer" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "WS Limit Test",
          "direction" => "sender",
          "site_url" => "https://ws-limit-#{System.unique_integer([:positive])}.com",
          "max_records_per_request" => 500
        })

      assert conn.max_records_per_request == 500
    end

    test "connection rate_limit_requests_per_minute is stored" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "WS Rate Limit Test",
          "direction" => "sender",
          "site_url" => "https://ws-rate-#{System.unique_integer([:positive])}.com",
          "rate_limit_requests_per_minute" => 30
        })

      assert conn.rate_limit_requests_per_minute == 30
    end
  end

  describe "connection helper functions used by websock" do
    test "active? checks status and limits" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Active Check",
          "direction" => "sender",
          "site_url" => "https://active-check-#{System.unique_integer([:positive])}.com"
        })

      # Pending connection is not active
      refute Connection.active?(conn)

      # Approve it
      {:ok, active_conn} = Connections.approve_connection(conn, UUIDv7.generate())
      assert Connection.active?(active_conn)
    end

    test "expired? checks expiration date" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Expired Check",
          "direction" => "sender",
          "site_url" => "https://expired-check-#{System.unique_integer([:positive])}.com",
          "expires_at" => past
        })

      assert Connection.expired?(conn)

      # Connection without expiration is not expired
      {:ok, conn2, _token} =
        Connections.create_connection(%{
          "name" => "No Expiry",
          "direction" => "sender",
          "site_url" => "https://no-expiry-#{System.unique_integer([:positive])}.com"
        })

      refute Connection.expired?(conn2)
    end

    test "ip_allowed? checks whitelist" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "IP Check",
          "direction" => "sender",
          "site_url" => "https://ip-check-#{System.unique_integer([:positive])}.com",
          "ip_whitelist" => ["192.168.1.1", "10.0.0.1"]
        })

      assert Connection.ip_allowed?(conn, "192.168.1.1")
      assert Connection.ip_allowed?(conn, "10.0.0.1")
      refute Connection.ip_allowed?(conn, "172.16.0.1")
    end

    test "empty ip_whitelist allows all IPs" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "No IP Restriction",
          "direction" => "sender",
          "site_url" => "https://no-ip-#{System.unique_integer([:positive])}.com",
          "ip_whitelist" => []
        })

      assert Connection.ip_allowed?(conn)
    end

    test "requires_approval? depends on approval_mode" do
      {:ok, auto, _} =
        Connections.create_connection(%{
          "name" => "Auto Mode",
          "direction" => "sender",
          "site_url" => "https://auto-mode-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "auto_approve"
        })

      {:ok, manual, _} =
        Connections.create_connection(%{
          "name" => "Manual Mode",
          "direction" => "sender",
          "site_url" => "https://manual-mode-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "require_approval"
        })

      {:ok, per_table, _} =
        Connections.create_connection(%{
          "name" => "Per Table Mode",
          "direction" => "sender",
          "site_url" => "https://per-table-mode-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "per_table",
          "auto_approve_tables" => ["users"]
        })

      refute Connection.requires_approval?(auto, "any_table")
      assert Connection.requires_approval?(manual, "any_table")
      refute Connection.requires_approval?(per_table, "users")
      assert Connection.requires_approval?(per_table, "secrets")
    end
  end
end
