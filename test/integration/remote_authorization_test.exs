defmodule PhoenixKitSync.Integration.RemoteAuthorizationTest do
  use PhoenixKitSync.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SyncableTable
  alias PhoenixKitSync.Test.Repo, as: TestRepo
  alias PhoenixKitSync.Web.SyncWebsock

  # The remote peer is the adversary. These tests drive the public surface
  # (the REST actions, the WebSocket upgrade, messages on an open socket)
  # as a peer would, and pin what it may and may not do.

  @table SyncableTable.name()
  @rest_actions ~w(list-tables pull-data table-schema table-records)

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)
    PhoenixKitSync.set_incoming_mode("require_approval")
    SyncableTable.insert!()
    :ok
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp unique_url, do: "https://peer-#{System.unique_integer([:positive])}.example.com"

  defp create(direction, attrs \\ %{}) do
    {:ok, connection, token} =
      Connections.create_connection(
        Map.merge(
          %{
            "name" => "Peer #{System.unique_integer([:positive])}",
            "direction" => direction,
            "site_url" => unique_url(),
            "status" => "active"
          },
          attrs
        )
      )

    {connection, token}
  end

  # Puts a connection in a status the way it gets there in production.
  defp in_status(direction, :pending), do: create(direction, %{"status" => "pending"})
  defp in_status(direction, :active), do: create(direction)
  defp in_status(direction, :expired), do: create(direction, %{"status" => "expired"})

  defp in_status(direction, :suspended_here) do
    {connection, token} = create(direction)

    {:ok, suspended} =
      Connections.suspend_connection(connection, actor_uuid: PhoenixKitSync.TestActor.uuid())

    {suspended, token}
  end

  defp in_status(direction, :revoked_here) do
    {connection, token} = create(direction)

    {:ok, revoked} =
      Connections.revoke_connection(connection, actor_uuid: PhoenixKitSync.TestActor.uuid())

    {revoked, token}
  end

  # Suspended by the peer's own earlier report.
  defp in_status("receiver", :suspended_by_peer) do
    {connection, token} = create("receiver")
    {:ok, suspended} = Connections.apply_remote_status(connection, "suspended")
    {suspended, token}
  end

  defp update_status(connection, token, status) do
    post(build_conn(), "/sync/api/update-status", %{
      "sender_url" => connection.site_url,
      "auth_token_hash" => token_hash(token),
      "status" => status
    })
  end

  defp status_of(connection), do: Connections.get_connection!(connection.uuid).status

  defp rest(action, token, extra \\ %{}, conn \\ build_conn()) do
    post(
      conn,
      "/sync/api/#{action}",
      Map.merge(%{"auth_token_hash" => token_hash(token), "table_name" => @table}, extra)
    )
  end

  defp upgrade(token, query \\ "") do
    build_conn()
    |> put_req_header("upgrade", "websocket")
    |> get("/sync/websocket?token=#{URI.encode_www_form(token)}#{query}")
  end

  # ===========================================
  # update-status: {current status} x {requested status} x {direction}
  # ===========================================

  describe "update-status" do
    # What a peer may change, written out: {state the row is in, status the
    # peer asks for} => the status the row has afterwards. Every pair not
    # listed is refused and leaves the row as it was.
    @allowed %{
      {:active, "suspended"} => "suspended",
      {:active, "revoked"} => "revoked",
      {:suspended_by_peer, "active"} => "active",
      {:suspended_by_peer, "revoked"} => "revoked"
    }

    @receiver_states [
      :pending,
      :active,
      :suspended_here,
      :suspended_by_peer,
      :revoked_here,
      :expired
    ]

    for state <- @receiver_states, requested <- ~w(active suspended revoked) do
      test "receiver row #{state}, peer asks for #{requested}" do
        state = unquote(state)
        requested = unquote(requested)
        {connection, token} = in_status("receiver", state)
        before = connection.status

        response = update_status(connection, token, requested)

        cond do
          expected = @allowed[{state, requested}] ->
            assert json_response(response, 200)["success"] == true
            assert status_of(connection) == expected

          before == requested ->
            # Already there: acknowledged, nothing written.
            assert json_response(response, 200)["success"] == true
            assert status_of(connection) == before

          true ->
            assert %{"success" => false, "error_code" => "status_change_not_allowed"} =
                     json_response(response, 409)

            assert status_of(connection) == before
        end
      end
    end

    for state <- [:pending, :active, :suspended_here, :revoked_here, :expired],
        requested <- ~w(active suspended revoked) do
      test "sender row #{state}, peer asks for #{requested}: the row is not even found" do
        {connection, token} = in_status("sender", unquote(state))
        before = connection.status

        response = update_status(connection, token, unquote(requested))

        assert json_response(response, 404)["success"] == false
        assert status_of(connection) == before
      end
    end

    test "a revoked peer cannot re-activate itself and then read", %{conn: conn} do
      {connection, token} = in_status("sender", :revoked_here)

      assert json_response(rest("list-tables", token, %{}, conn), 403)
      assert json_response(update_status(connection, token, "active"), 404)
      assert status_of(connection) == "revoked"
      assert json_response(rest("pull-data", token), 403)
    end

    test "a suspension the peer reported stops being the peer's once an admin acts on it" do
      {connection, token} = in_status("receiver", :suspended_by_peer)
      assert Connection.remote_suspended?(connection)

      {:ok, reactivated} = Connections.reactivate_connection(connection)

      {:ok, suspended_here} =
        Connections.suspend_connection(reactivated, actor_uuid: PhoenixKitSync.TestActor.uuid())

      refute Connection.remote_suspended?(suspended_here)
      assert json_response(update_status(suspended_here, token, "active"), 409)
      assert status_of(connection) == "suspended"
    end

    test "the transition rule is in the context, not only in the controller" do
      {sender, _token} = in_status("sender", :revoked_here)

      assert {:error, :status_change_not_allowed} =
               Connections.apply_remote_status(sender, "active")

      {pending, _token} = in_status("receiver", :pending)

      assert {:error, :status_change_not_allowed} =
               Connections.apply_remote_status(pending, "active")

      assert status_of(pending) == "pending"
    end

    test "a status the peer changed is in the activity log, with no actor" do
      {connection, token} = in_status("receiver", :active)
      assert json_response(update_status(connection, token, "suspended"), 200)

      assert_activity_logged("sync.connection.suspended",
        resource_uuid: connection.uuid,
        metadata_has: %{"reason" => "remote_site"}
      )
    end
  end

  # ===========================================
  # One authorization for REST and the socket: restriction x entry point
  # ===========================================

  describe "connection restrictions" do
    # An hour window that never contains the current hour.
    defp closed_hours do
      hour = DateTime.utc_now().hour
      %{allowed_hours_start: rem(hour + 2, 24), allowed_hours_end: rem(hour + 3, 24)}
    end

    defp restrictions do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      [
        {"suspended", %{status: "suspended"}, "connection_not_active", "Connection not active"},
        {"revoked", %{status: "revoked"}, "connection_not_active", "Connection not active"},
        {"pending", %{status: "pending"}, "connection_not_active", "Connection not active"},
        {"expired", %{expires_at: past}, "connection_expired", "Connection expired"},
        {"out of downloads", %{max_downloads: 1, downloads_used: 1}, "download_limit_reached",
         "Download limit reached"},
        {"out of records", %{max_records_total: 5, records_downloaded: 5}, "record_limit_reached",
         "Record limit reached"},
        {"IP not whitelisted", %{ip_whitelist: ["203.0.113.9"]}, "ip_not_allowed",
         "IP not allowed"},
        {"outside allowed hours", closed_hours(), "outside_allowed_hours",
         "Outside allowed hours"},
        {"download password", %{download_password: "s3cret"}, "invalid_password",
         "Invalid password"}
      ]
    end

    test "an unrestricted connection passes every entry point (the control)" do
      {_connection, token} = create("sender")

      for action <- @rest_actions do
        assert json_response(rest(action, token), 200)["success"] == true, action
      end

      assert {:ok, _connection} = Connections.validate_connection(token, "127.0.0.1")
    end

    test "each restriction is refused by every REST action and by the socket upgrade" do
      for {name, attrs, code, socket_text} <- restrictions() do
        {connection, token} = create("sender")
        {:ok, _} = Connections.update_connection(connection, attrs)

        for action <- @rest_actions do
          assert %{"success" => false, "error_code" => ^code} =
                   json_response(rest(action, token), 403),
                 "#{action} let a connection through that is #{name}"
        end

        response = upgrade(token)
        assert response.status == 403, "the socket upgrade let through: #{name}"
        assert response.resp_body == socket_text
      end
    end

    test "each restriction is refused on a socket that was opened before it applied" do
      for {name, attrs, code, _socket_text} <- restrictions() do
        {connection, _token} = create("sender")

        {:ok, state} =
          SyncWebsock.init(
            auth_type: :connection,
            connection: connection,
            connection_info: %{remote_ip: "127.0.0.1"}
          )

        state = %{state | joined: true}
        assert %{"records" => [_ | _]} = socket_request(state, connection, "request:records")

        {:ok, _} = Connections.update_connection(connection, attrs)

        for event <- ~w(request:tables request:schema request:count request:records) do
          assert %{"error" => error} = socket_request(state, connection, event)

          assert error == PhoenixKitSync.Errors.message(String.to_existing_atom(code)),
                 "#{event} answered on a socket whose connection is now #{name}"
        end
      end
    end

    test "a deleted connection's open socket is refused" do
      {connection, _token} = create("sender")
      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: connection)
      {:ok, _} = Connections.delete_connection(connection)

      assert %{"error" => "Connection is not active"} =
               socket_request(%{state | joined: true}, connection, "request:records")
    end

    test "the download password opens REST and the socket when it is right" do
      {connection, token} = create("sender")
      {:ok, _} = Connections.update_connection(connection, %{download_password: "s3cret"})

      for action <- @rest_actions do
        assert json_response(rest(action, token, %{"password" => "s3cret"}), 200)["success"],
               action

        assert json_response(rest(action, token, %{"password" => "wrong"}), 403)
        assert json_response(rest(action, token, %{"password" => %{"a" => 1}}), 403)
      end

      assert {:ok, _} = Connections.validate_connection(token, "127.0.0.1", password: "s3cret")
      assert upgrade(token, "&password=wrong").resp_body == "Invalid password"
    end

    test "a narrowed table list holds on an open socket" do
      {connection, _token} = create("sender")
      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: connection)
      state = %{state | joined: true}

      {:ok, _} = Connections.update_connection(connection, %{allowed_tables: ["some_other"]})

      assert %{"error" => "Access denied to table: " <> @table} =
               socket_request(state, connection, "request:records")
    end

    test "the token of a receiver row opens nothing on this site" do
      {_connection, token} = create("receiver")

      for action <- @rest_actions do
        assert json_response(rest(action, token), 401)["success"] == false, action
      end

      assert upgrade(token).resp_body == "Invalid token"
      assert {:error, :invalid_token} = Connections.validate_connection(token, "127.0.0.1")
    end

    test "authorize_request/3 itself refuses a receiver row" do
      {connection, _token} = create("receiver")
      assert {:error, :unauthorized} = Connections.authorize_request(connection, "127.0.0.1")
    end

    test "a page never carries a connection past its record allowance" do
      for _ <- 1..4, do: SyncableTable.insert!()
      {connection, token} = create("sender")
      {:ok, _} = Connections.update_connection(connection, %{max_records_total: 3})

      body = json_response(rest("pull-data", token), 200)
      assert length(body["data"]) == 3
      assert Connections.get_connection!(connection.uuid).records_downloaded == 3

      assert %{"error_code" => "record_limit_reached"} =
               json_response(rest("pull-data", token), 403)
    end
  end

  defp socket_request(state, connection, event) do
    payload =
      Jason.encode!([
        nil,
        "1",
        "transfer:conn:#{connection.uuid}",
        event,
        %{"table" => @table, "ref" => "r"}
      ])

    {:push, {:text, reply}, _state} = SyncWebsock.handle_in({payload, [opcode: :text]}, state)
    [_join_ref, _ref, _topic, _event, response] = Jason.decode!(reply)
    response
  end

  # ===========================================
  # Counters
  # ===========================================

  describe "transfer counters" do
    test "every request on one socket is counted, though the socket holds an old copy" do
      {connection, _token} = create("sender")
      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: connection)
      state = %{state | joined: true}

      for _ <- 1..3, do: socket_request(state, connection, "request:records")

      counted = Connections.get_connection!(connection.uuid)
      assert counted.downloads_used == 3
      assert counted.total_transfers == 3
      assert counted.records_downloaded == 3
    end

    test "record_transfer/2 adds to the row in the database, not to the caller's copy" do
      {stale, _token} = create("sender")

      assert {:ok, _} = Connections.record_transfer(stale, %{records_count: 10})
      assert {:ok, counted} = Connections.record_transfer(stale, %{records_count: 5})

      assert counted.downloads_used == 2
      assert counted.records_downloaded == 15
      assert counted.total_records_transferred == 15
    end

    test "each REST pull adds one download and its records" do
      {connection, token} = create("sender")

      for _ <- 1..2, do: assert(json_response(rest("pull-data", token), 200))

      counted = Connections.get_connection!(connection.uuid)
      assert counted.downloads_used == 2
      assert counted.records_downloaded == 2
    end
  end

  # ===========================================
  # Client address
  # ===========================================

  describe "IP whitelist" do
    setup do
      {connection, token} = create("sender")
      {:ok, _} = Connections.update_connection(connection, %{ip_whitelist: ["203.0.113.9"]})
      {:ok, token: token}
    end

    test "a client cannot name a whitelisted address in X-Forwarded-For", %{token: token} do
      direct = %{build_conn() | remote_ip: {198, 51, 100, 7}}

      spoofed = put_req_header(direct, "x-forwarded-for", "203.0.113.9")

      for conn <- [direct, spoofed], action <- @rest_actions do
        assert %{"error_code" => "ip_not_allowed"} =
                 json_response(rest(action, token, %{}, conn), 403)
      end

      socket =
        spoofed
        |> put_req_header("upgrade", "websocket")
        |> get("/sync/websocket?token=#{token}")

      assert socket.resp_body == "IP not allowed"
    end

    test "behind a proxy on this box, the hop the proxy appended decides", %{token: token} do
      proxied = fn forwarded ->
        put_req_header(%{build_conn() | remote_ip: {127, 0, 0, 1}}, "x-forwarded-for", forwarded)
      end

      # The client claimed the whitelisted address; the proxy saw another.
      assert %{"error_code" => "ip_not_allowed"} =
               json_response(
                 rest("list-tables", token, %{}, proxied.("203.0.113.9, 198.51.100.7")),
                 403
               )

      assert json_response(
               rest("list-tables", token, %{}, proxied.("10.9.9.9, 203.0.113.9")),
               200
             )["success"]
    end

    test "the whitelisted address itself gets through", %{token: token} do
      conn = %{build_conn() | remote_ip: {203, 0, 113, 9}}
      assert json_response(rest("list-tables", token, %{}, conn), 200)["success"]
    end
  end

  # ===========================================
  # register-connection
  # ===========================================

  describe "register-connection" do
    defp register(extra \\ %{}) do
      url = unique_url()

      response =
        post(
          build_conn(),
          "/sync/api/register-connection",
          Map.merge(
            %{
              "sender_url" => url,
              "connection_name" => "Remote",
              "auth_token" => "token-#{System.unique_integer([:positive])}"
            },
            extra
          )
        )

      {response, url}
    end

    test "under require_approval (the default) an unauthenticated request is created pending" do
      {response, url} = register()

      assert %{"success" => true, "connection_status" => "pending"} = json_response(response, 200)
      assert Connections.find_by_site_url(url, "receiver").status == "pending"
    end

    test "with no mode set at all, the result is still pending" do
      TestRepo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'sync_incoming_mode'")
      assert PhoenixKitSync.get_incoming_mode() == "require_approval"

      {response, url} = register()
      assert json_response(response, 200)["connection_status"] == "pending"
      assert Connections.find_by_site_url(url, "receiver").status == "pending"
    end

    test "auto_accept activates" do
      PhoenixKitSync.set_incoming_mode("auto_accept")
      {response, url} = register()

      assert json_response(response, 200)["connection_status"] == "active"
      assert Connections.find_by_site_url(url, "receiver").status == "active"
    end

    test "require_password activates only on the right password" do
      PhoenixKitSync.set_incoming_mode("require_password")
      PhoenixKitSync.set_incoming_password("opensesame")

      {wrong, wrong_url} = register(%{"password" => "nope"})
      assert json_response(wrong, 401)["success"] == false
      assert Connections.find_by_site_url(wrong_url, "receiver") == nil

      {missing, _url} = register()
      assert json_response(missing, 401)["success"] == false

      {right, url} = register(%{"password" => "opensesame"})
      assert json_response(right, 200)["connection_status"] == "active"
      assert Connections.find_by_site_url(url, "receiver").status == "active"
    end

    test "deny_all creates nothing" do
      PhoenixKitSync.set_incoming_mode("deny_all")
      {response, url} = register()

      assert json_response(response, 403)["success"] == false
      assert Connections.find_by_site_url(url, "receiver") == nil
    end

    test "a pending registration grants the registrant nothing" do
      token = "attacker-token-#{System.unique_integer([:positive])}"
      {response, _url} = register(%{"auth_token" => token})
      assert json_response(response, 200)["connection_status"] == "pending"

      for action <- @rest_actions do
        assert json_response(rest(action, token), 401)["success"] == false
      end

      assert upgrade(token).status == 403
    end

    test "registrations waiting for approval are capped" do
      Application.put_env(:phoenix_kit_sync, :max_pending_incoming, 2)
      on_exit(fn -> Application.delete_env(:phoenix_kit_sync, :max_pending_incoming) end)

      for _ <- 1..2 do
        {response, _url} = register()
        assert json_response(response, 200)["connection_status"] == "pending"
      end

      {refused, url} = register()
      assert json_response(refused, 429)["success"] == false
      assert Connections.find_by_site_url(url, "receiver") == nil
      assert Connections.count_connections(direction: "receiver", status: "pending") == 2

      # The cap is on what waits for an admin; an accepting mode is not held to it.
      PhoenixKitSync.set_incoming_mode("auto_accept")
      {accepted, _url} = register()
      assert json_response(accepted, 200)["connection_status"] == "active"
    end

    test "a second registration for the same site is refused" do
      url = unique_url()
      body = %{"sender_url" => url, "connection_name" => "Remote", "auth_token" => "t1"}

      assert json_response(post(build_conn(), "/sync/api/register-connection", body), 200)

      assert json_response(
               post(build_conn(), "/sync/api/register-connection", %{body | "auth_token" => "t2"}),
               409
             )

      assert Connections.count_connections(direction: "receiver") == 1
    end

    test "an oversized name or URL is a 400, not a database error" do
      {long_name, _url} = register(%{"connection_name" => String.duplicate("n", 300)})
      assert json_response(long_name, 400)["success"] == false

      {long_url, _url} =
        register(%{"sender_url" => "https://example.com/" <> String.duplicate("a", 300)})

      assert json_response(long_url, 400)["success"] == false
    end
  end

  # ===========================================
  # Tables that are never synced
  # ===========================================

  describe "credential tables" do
    @secret_tables ~w(phoenix_kit_sync_connections phoenix_kit_sync_transfers phoenix_kit_settings
                      phoenix_kit_users_tokens phoenix_kit_user_oauth_providers
                      phoenix_kit_ai_accounts phoenix_kit_ai_endpoints phoenix_kit_buckets
                      phoenix_kit_payment_provider_configs phoenix_kit_organization_invitations)

    test "REST refuses each one, even for a connection that lists it as allowed" do
      PhoenixKitSync.set_incoming_password("the-incoming-password")

      for allowed <- [[], @secret_tables], table <- @secret_tables do
        {connection, token} = create("sender")
        {:ok, _} = Connections.update_connection(connection, %{allowed_tables: allowed})

        for action <- ~w(pull-data table-schema table-records) do
          response = rest(action, token, %{"table_name" => table})

          assert json_response(response, 403)["success"] == false,
                 "#{action} served #{table}"

          refute response.resp_body =~ "the-incoming-password"
          refute response.resp_body =~ "auth_token_hash"
        end
      end
    end

    test "list-tables names none of them" do
      {_connection, token} = create("sender")
      names = Enum.map(json_response(rest("list-tables", token), 200)["tables"], & &1["name"])

      assert @table in names
      for table <- @secret_tables, do: refute(table in names)
    end

    test "a code-based session cannot read them either" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: session.code, session: session)
      state = %{state | joined: true}

      list = session_request(state, "request:tables", %{"ref" => "r"})
      names = Enum.map(list["tables"], & &1["name"])
      assert @table in names
      for table <- @secret_tables, do: refute(table in names)

      for table <- @secret_tables, event <- ~w(request:schema request:count request:records) do
        response = session_request(state, event, %{"table" => table, "ref" => "r"})
        assert response["error"], "#{event} answered for #{table}: #{inspect(response)}"
        refute Map.has_key?(response, "records")
        refute Map.has_key?(response, "schema")
        refute Map.has_key?(response, "count")
      end
    end

    test "nothing imports into them" do
      for table <- @secret_tables do
        assert {:error, :table_excluded} =
                 PhoenixKitSync.DataImporter.import_records(table, [%{"key" => "x"}], :overwrite)

        assert {:error, :table_excluded} =
                 PhoenixKitSync.ConnectionNotifier.pull_table_data(
                   %{site_url: "https://sender.example.com", auth_token_hash: "h"},
                   table
                 )
      end
    end

    test "the host can add its own tables to the list" do
      refute PhoenixKitSync.SchemaInspector.excluded_table?("my_app_partners")
      Application.put_env(:phoenix_kit_sync, :excluded_tables, ["my_app_partners"])
      on_exit(fn -> Application.delete_env(:phoenix_kit_sync, :excluded_tables) end)

      assert PhoenixKitSync.SchemaInspector.excluded_table?("my_app_partners")
    end
  end

  defp session_request(state, event, payload) do
    frame = Jason.encode!([nil, "1", "transfer:#{state.code}", event, payload])
    {:push, {:text, reply}, _state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
    [_join_ref, _ref, _topic, _event, response] = Jason.decode!(reply)
    response
  end

  # ===========================================
  # Malformed input
  # ===========================================

  describe "parameters that are not strings" do
    @not_strings [5, true, ["a"], %{"a" => 1}]

    test "answer 400 on every action that requires them" do
      {connection, token} = create("sender")
      hash = token_hash(token)

      requests = [
        {"register-connection",
         %{"sender_url" => unique_url(), "connection_name" => "x", "auth_token" => "t"}},
        {"delete-connection", %{"sender_url" => connection.site_url, "auth_token_hash" => hash}},
        {"verify-connection", %{"sender_url" => connection.site_url, "auth_token_hash" => hash}},
        {"update-status",
         %{"sender_url" => connection.site_url, "auth_token_hash" => hash, "status" => "active"}},
        {"get-connection-status", %{"receiver_url" => unique_url(), "auth_token_hash" => hash}},
        {"list-tables", %{"auth_token_hash" => hash}},
        {"pull-data", %{"auth_token_hash" => hash, "table_name" => @table}},
        {"table-schema", %{"auth_token_hash" => hash, "table_name" => @table}},
        {"table-records", %{"auth_token_hash" => hash, "table_name" => @table}}
      ]

      for {action, body} <- requests, {field, _value} <- body, bad <- @not_strings do
        response = post(build_conn(), "/sync/api/#{action}", Map.put(body, field, bad))

        assert response.status == 400,
               "#{action} with #{field}=#{inspect(bad)} answered #{response.status}"
      end

      assert Connections.get_connection!(connection.uuid).status == "active"
    end

    test "a conflict_strategy that is not a string does not fail the pull" do
      {_connection, token} = create("sender")

      assert json_response(rest("pull-data", token, %{"conflict_strategy" => %{"a" => 1}}), 200)
    end

    test "a token or code that is not a string is not a credential" do
      for query <- ["token[a]=1", "code[a]=1"] do
        response =
          build_conn()
          |> put_req_header("upgrade", "websocket")
          |> get("/sync/websocket?" <> query)

        assert response.status == 403
      end
    end
  end

  describe "frames that are not channel frames" do
    test "the server socket ignores them and stays up" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: session.code, session: session)

      for frame <- [
            "{}",
            "5",
            "null",
            ~s("text"),
            "[]",
            "[1,2,3]",
            "[1,2,3,4,5,6]",
            ~s([null,"1",{"a":1},"request:tables",{}]),
            ~s([null,"1","transfer:ABCD2345",["x"],{}])
          ] do
        assert {:ok, ^state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state), frame
      end
    end

    test "a join whose payload is not an object still joins without crashing" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: session.code, session: session)

      for payload <- ["5", "[1]", ~s("x"), ~s({"receiver_info":7})] do
        frame = ~s([null,"1","transfer:#{session.code}","phx_join",#{payload}])

        assert {:push, {:text, _reply}, %{joined: true}} =
                 SyncWebsock.handle_in({frame, [opcode: :text]}, state)
      end
    end

    test "a table name that is not a string gets no answer and no crash" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: session.code, session: session)
      state = %{state | joined: true}

      for event <- ~w(request:schema request:count request:records) do
        frame =
          Jason.encode!([
            nil,
            "1",
            "transfer:ABCD2345",
            event,
            %{"table" => %{"a" => 1}, "ref" => "r"}
          ])

        assert {:ok, ^state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
      end
    end
  end

  # ===========================================
  # Session codes
  # ===========================================

  describe "session codes" do
    test "are not written to the log, valid or not" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      guess = "ZZZZ9999"

      attempt = fn code ->
        build_conn()
        |> put_req_header("upgrade", "websocket")
        |> get("/sync/websocket?code=#{code}")
      end

      log =
        capture_log(fn ->
          assert attempt.(guess).status == 403

          # The valid code is accepted and logged as such before the upgrade,
          # which the test adapter cannot perform.
          assert_raise WebSockAdapter.UpgradeError, fn -> attempt.(session.code) end

          # Now used: refused, and that refusal does not log it either.
          assert attempt.(session.code).resp_body == "Code already used"
        end)

      assert log =~ "Invalid session code attempt"
      assert log =~ "Session code already used"
      refute log =~ guess
      refute log =~ session.code
    end

    test "of many connections racing on one code, exactly one is accepted" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> PhoenixKitSync.validate_code(session.code) end) end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_used})) == 49
    end

    test "a later update does not make a used code usable again" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      assert {:ok, _} = PhoenixKitSync.validate_code(session.code)

      # What a caller holding the session from before the connect would write.
      assert {:ok, merged} = PhoenixKitSync.update_session(session.code, %{receiver_info: %{}})
      assert merged.status == :connected
      assert {:error, :already_used} = PhoenixKitSync.validate_code(session.code)
    end

    test "do not come from the seedable generator" do
      seeded = fn ->
        :rand.seed(:exsss, {1, 2, 3})
        {:ok, session} = PhoenixKitSync.create_session(:send)
        session.code
      end

      # With :rand the same seed gives the same code twice.
      assert seeded.() != seeded.()
    end
  end
end
