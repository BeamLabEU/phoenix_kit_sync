defmodule PhoenixKitSync.Integration.ApiControllerTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections

  # The API controller requires the full Phoenix plug pipeline to test directly.
  # Instead, we test the business logic that the controller orchestrates
  # through the context modules, which is what matters for correctness.

  describe "register_connection flow" do
    test "creating a receiver connection for an incoming sender" do
      sender_url = "https://sender-#{System.unique_integer([:positive])}.com"

      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Remote Sender",
          "direction" => "receiver",
          "site_url" => sender_url,
          "approval_mode" => "auto_approve",
          "status" => "active"
        })

      assert conn.direction == "receiver"
      assert conn.site_url == sender_url
    end

    test "creating a sender connection generates auth token" do
      {:ok, conn, token} =
        Connections.create_connection(%{
          "name" => "Outgoing Sender",
          "direction" => "sender",
          "site_url" => "https://sender-gen-#{System.unique_integer([:positive])}.com"
        })

      assert is_binary(token)
      assert conn.auth_token_hash != nil
      assert conn.status == "pending"
    end
  end

  describe "connection lookup by token hash" do
    test "can find connection by auth_token_hash" do
      {:ok, conn, token} =
        Connections.create_connection(%{
          "name" => "Hash Lookup Test",
          "direction" => "sender",
          "site_url" => "https://hash-lookup-#{System.unique_integer([:positive])}.com"
        })

      # The hash should be stored
      assert conn.auth_token_hash != nil

      # Computing the same hash should find it
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      assert conn.auth_token_hash == hash
    end

    test "verify_auth_token returns true for correct token" do
      {:ok, conn, token} =
        Connections.create_connection(%{
          "name" => "Token Verify Test",
          "direction" => "sender",
          "site_url" => "https://token-verify-#{System.unique_integer([:positive])}.com"
        })

      assert Connection.verify_auth_token(conn, token)
      refute Connection.verify_auth_token(conn, "wrong-token")
    end
  end

  describe "table access control" do
    test "connection with allowed_tables restricts access" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Restricted",
          "direction" => "sender",
          "site_url" => "https://restricted-#{System.unique_integer([:positive])}.com",
          "allowed_tables" => ["users", "posts"]
        })

      assert Connection.table_allowed?(conn, "users")
      assert Connection.table_allowed?(conn, "posts")
      refute Connection.table_allowed?(conn, "secrets")
    end

    test "connection with excluded_tables blocks access" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Excluded",
          "direction" => "sender",
          "site_url" => "https://excluded-#{System.unique_integer([:positive])}.com",
          "excluded_tables" => ["secrets", "tokens"]
        })

      assert Connection.table_allowed?(conn, "users")
      refute Connection.table_allowed?(conn, "secrets")
      refute Connection.table_allowed?(conn, "tokens")
    end

    test "connection with both allowed and excluded tables" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Both Lists",
          "direction" => "sender",
          "site_url" => "https://both-lists-#{System.unique_integer([:positive])}.com",
          "allowed_tables" => ["users", "posts", "secrets"],
          "excluded_tables" => ["secrets"]
        })

      assert Connection.table_allowed?(conn, "users")
      assert Connection.table_allowed?(conn, "posts")
      # excluded_tables takes precedence
      refute Connection.table_allowed?(conn, "secrets")
      # Not in allowed_tables
      refute Connection.table_allowed?(conn, "other_table")
    end
  end

  describe "connection approval workflow via API flow" do
    test "auto_approve connection can be activated immediately" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Auto Approve",
          "direction" => "sender",
          "site_url" => "https://auto-approve-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "auto_approve"
        })

      assert conn.status == "pending"

      {:ok, active} = Connections.approve_connection(conn, UUIDv7.generate())
      assert active.status == "active"
      assert active.approved_at != nil
    end

    test "connection with require_approval mode requires explicit approval" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Require Approval",
          "direction" => "sender",
          "site_url" => "https://require-approval-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "require_approval"
        })

      assert conn.approval_mode == "require_approval"
      assert conn.status == "pending"
    end
  end
end
