defmodule PhoenixKitSync.Integration.ApiControllerEndpointsTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.Connections

  # Plug-pipeline tests for every public action on
  # PhoenixKitSync.Web.ApiController. Routes are registered in
  # `Test.Router` under `/sync/api/*` to mirror the production layout.
  #
  # The 10 actions:
  #   register_connection / delete_connection / verify_connection
  #   update_status / get_connection_status
  #   list_tables / pull_data / table_schema / table_records
  #   status
  #
  # For each, the tests assert: the happy path returns 200, missing
  # required fields returns 400, an unknown auth_token_hash returns
  # 401/404, an inactive connection returns 403, and table-authz
  # rejections return 403 (where applicable).

  defp create_active_sender(attrs \\ %{}) do
    defaults = %{
      "name" => "Test Sender #{System.unique_integer([:positive])}",
      "direction" => "sender",
      "site_url" =>
        Map.get(attrs, "site_url") ||
          "https://api-test-#{System.unique_integer([:positive])}.example.com",
      "approval_mode" => "auto_approve"
    }

    {:ok, conn, token} = Connections.create_connection(Map.merge(defaults, attrs))
    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    {active, token}
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  setup do
    # Make sure the module is enabled for the duration of these tests
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)
    :ok
  end

  describe "GET /sync/api/status" do
    test "returns module enabled flag and incoming mode", %{conn: conn} do
      conn = get(conn, "/sync/api/status")
      body = json_response(conn, 200)

      assert body["enabled"] == true
      assert is_binary(body["incoming_mode"]) or is_nil(body["incoming_mode"])
      assert is_boolean(body["password_required"])
    end
  end

  describe "POST /sync/api/register-connection" do
    test "rejects missing fields with 400", %{conn: conn} do
      conn = post(conn, "/sync/api/register-connection", %{})
      body = json_response(conn, 400)

      assert body["success"] == false
      assert is_list(body["fields"])
      assert "sender_url" in body["fields"]
    end

    test "rejects when module is disabled with 503", %{conn: conn} do
      PhoenixKitSync.disable_system()

      conn =
        post(conn, "/sync/api/register-connection", %{
          "sender_url" => "https://remote.example.com",
          "connection_name" => "Disabled-test",
          "auth_token" => "tok-#{System.unique_integer([:positive])}"
        })

      assert json_response(conn, 503)["success"] == false
    end

    test "creates a receiver connection on the happy path", %{conn: conn} do
      sender_url = "https://reg-happy-#{System.unique_integer([:positive])}.example.com"

      conn =
        post(conn, "/sync/api/register-connection", %{
          "sender_url" => sender_url,
          "connection_name" => "Reg Happy",
          "auth_token" => "happy-token-#{System.unique_integer([:positive])}"
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert is_binary(body["connection_uuid"])
    end

    test "rejects with 401 when password mode is on but no password is configured", %{conn: conn} do
      PhoenixKitSync.set_incoming_mode("require_password")
      PhoenixKitSync.set_incoming_password(nil)

      conn =
        post(conn, "/sync/api/register-connection", %{
          "sender_url" => "https://reg-no-pwd.example.com",
          "connection_name" => "PwdTest",
          "auth_token" => "tok"
        })

      body = json_response(conn, 401)
      assert body["success"] == false

      # Cleanup
      PhoenixKitSync.set_incoming_mode("auto_accept")
    end

    test "accepts when password matches", %{conn: conn} do
      PhoenixKitSync.set_incoming_mode("require_password")
      PhoenixKitSync.set_incoming_password("right-pwd")

      conn =
        post(conn, "/sync/api/register-connection", %{
          "sender_url" => "https://reg-pwd-ok-#{System.unique_integer([:positive])}.example.com",
          "connection_name" => "PwdOk",
          "auth_token" => "tok-#{System.unique_integer([:positive])}",
          "password" => "right-pwd"
        })

      assert json_response(conn, 200)["success"] == true

      PhoenixKitSync.set_incoming_mode("auto_accept")
      PhoenixKitSync.set_incoming_password(nil)
    end

    test "rejects with 401 on wrong password", %{conn: conn} do
      PhoenixKitSync.set_incoming_mode("require_password")
      PhoenixKitSync.set_incoming_password("right-pwd")

      conn =
        post(conn, "/sync/api/register-connection", %{
          "sender_url" => "https://reg-wrong-#{System.unique_integer([:positive])}.example.com",
          "connection_name" => "WrongPwd",
          "auth_token" => "tok",
          "password" => "wrong-pwd"
        })

      assert json_response(conn, 401)["success"] == false

      PhoenixKitSync.set_incoming_mode("auto_accept")
      PhoenixKitSync.set_incoming_password(nil)
    end
  end

  describe "POST /sync/api/list-tables" do
    test "missing auth_token_hash returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/list-tables", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "unknown token hash returns 401", %{conn: conn} do
      conn =
        post(conn, "/sync/api/list-tables", %{
          "auth_token_hash" => String.duplicate("a", 64)
        })

      assert json_response(conn, 401)["success"] == false
    end

    test "inactive connection returns 403", %{conn: conn} do
      {connection, token} = create_active_sender()
      Connections.suspend_connection(connection, PhoenixKitSync.TestActor.uuid())

      conn =
        post(conn, "/sync/api/list-tables", %{
          "auth_token_hash" => token_hash(token)
        })

      assert json_response(conn, 403)["success"] == false
    end

    test "happy path returns success and a table list", %{conn: conn} do
      {_connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/list-tables", %{
          "auth_token_hash" => token_hash(token)
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert is_list(body["tables"])
    end

    test "tables list filters by connection's allowed_tables and excluded_tables", %{conn: conn} do
      {connection, token} = create_active_sender()

      # Restrict the connection to a non-existent table — the result list
      # should be empty even though there are real tables in the DB.
      Connections.update_connection(connection, %{
        "allowed_tables" => ["nonexistent_table_xyz"]
      })

      conn =
        post(conn, "/sync/api/list-tables", %{
          "auth_token_hash" => token_hash(token)
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert body["tables"] == []
    end
  end

  describe "POST /sync/api/pull-data" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/pull-data", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "unknown token returns 401", %{conn: conn} do
      conn =
        post(conn, "/sync/api/pull-data", %{
          "auth_token_hash" => String.duplicate("b", 64),
          "table_name" => "phoenix_kit_sync_connections"
        })

      assert json_response(conn, 401)["success"] == false
    end

    test "table not in allowed_tables returns 403", %{conn: conn} do
      {connection, token} = create_active_sender()

      Connections.update_connection(connection, %{
        "allowed_tables" => ["phoenix_kit_sync_connections"]
      })

      conn =
        post(conn, "/sync/api/pull-data", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_transfers"
        })

      assert json_response(conn, 403)["success"] == false
    end

    test "happy path returns success and data", %{conn: conn} do
      {_connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/pull-data", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_connections"
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert is_list(body["data"])
    end
  end

  describe "POST /sync/api/table-schema" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/table-schema", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "table not allowed returns 403", %{conn: conn} do
      {connection, token} = create_active_sender()

      Connections.update_connection(connection, %{
        "excluded_tables" => ["phoenix_kit_sync_connections"]
      })

      conn =
        post(conn, "/sync/api/table-schema", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_connections"
        })

      assert json_response(conn, 403)["success"] == false
    end

    test "happy path returns schema", %{conn: conn} do
      {_connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/table-schema", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_connections"
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert is_map(body["schema"])
    end

    test "non-existent table returns 404", %{conn: conn} do
      {_connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/table-schema", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "nonexistent_table_zzz"
        })

      assert json_response(conn, 404)["success"] == false
    end
  end

  describe "POST /sync/api/table-records" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/table-records", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "table not allowed returns 403", %{conn: conn} do
      {connection, token} = create_active_sender()

      Connections.update_connection(connection, %{
        "excluded_tables" => ["phoenix_kit_sync_connections"]
      })

      conn =
        post(conn, "/sync/api/table-records", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_connections"
        })

      assert json_response(conn, 403)["success"] == false
    end

    test "happy path returns records", %{conn: conn} do
      {_connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/table-records", %{
          "auth_token_hash" => token_hash(token),
          "table_name" => "phoenix_kit_sync_connections",
          "limit" => "5"
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert is_list(body["records"])
    end
  end

  describe "POST /sync/api/verify-connection" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/verify-connection", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "unknown token returns 404", %{conn: conn} do
      conn =
        post(conn, "/sync/api/verify-connection", %{
          "sender_url" => "https://wherever.example.com",
          "auth_token_hash" => String.duplicate("c", 64)
        })

      assert json_response(conn, 404)["success"] == false
    end

    test "valid connection returns 200 with exists: true", %{conn: conn} do
      {connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/verify-connection", %{
          "sender_url" => connection.site_url,
          "auth_token_hash" => token_hash(token)
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert body["exists"] == true
    end
  end

  describe "POST /sync/api/update-status" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/update-status", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "invalid status value returns 400", %{conn: conn} do
      {connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/update-status", %{
          "sender_url" => connection.site_url,
          "auth_token_hash" => token_hash(token),
          "status" => "potato"
        })

      assert json_response(conn, 400)["success"] == false
    end

    test "unknown connection returns 404", %{conn: conn} do
      conn =
        post(conn, "/sync/api/update-status", %{
          "sender_url" => "https://nope.example.com",
          "auth_token_hash" => String.duplicate("d", 64),
          "status" => "suspended"
        })

      assert json_response(conn, 404)["success"] == false
    end

    test "valid update transitions status", %{conn: conn} do
      {connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/update-status", %{
          "sender_url" => connection.site_url,
          "auth_token_hash" => token_hash(token),
          "status" => "suspended"
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert Connections.get_connection!(connection.uuid).status == "suspended"
    end
  end

  describe "POST /sync/api/get-connection-status" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/get-connection-status", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "unknown token returns 404", %{conn: conn} do
      conn =
        post(conn, "/sync/api/get-connection-status", %{
          "receiver_url" => "https://nope.example.com",
          "auth_token_hash" => String.duplicate("e", 64)
        })

      assert json_response(conn, 404)["success"] == false
    end

    test "valid connection returns its status", %{conn: conn} do
      {connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/get-connection-status", %{
          "receiver_url" => "https://anywhere.example.com",
          "auth_token_hash" => token_hash(token)
        })

      body = json_response(conn, 200)
      assert body["success"] == true
      assert body["status"] == connection.status
    end
  end

  describe "POST /sync/api/delete-connection" do
    test "missing fields returns 400", %{conn: conn} do
      conn = post(conn, "/sync/api/delete-connection", %{})
      assert json_response(conn, 400)["success"] == false
    end

    test "unknown connection returns 404", %{conn: conn} do
      conn =
        post(conn, "/sync/api/delete-connection", %{
          "sender_url" => "https://nope.example.com",
          "auth_token_hash" => String.duplicate("f", 64)
        })

      assert json_response(conn, 404)["success"] == false
    end

    test "valid delete removes the connection", %{conn: conn} do
      {connection, token} = create_active_sender()

      conn =
        post(conn, "/sync/api/delete-connection", %{
          "sender_url" => connection.site_url,
          "auth_token_hash" => token_hash(token)
        })

      assert json_response(conn, 200)["success"] == true
      assert Connections.get_connection(connection.uuid) == nil
    end
  end
end
