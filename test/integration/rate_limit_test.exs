defmodule PhoenixKitSync.Integration.RateLimitTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.RateLimit
  alias PhoenixKitSync.SyncableTable
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer
  alias PhoenixKitSync.Web.SyncWebsock
  alias PhoenixKitSync.WebSocketClient

  # A connection's requests per minute, on the sending side (every entry
  # point that authorizes a request counts it) and on the receiving side
  # (a 429 is waited out, within bounds the peer cannot move).

  @table SyncableTable.name()
  @rest_actions ~w(list-tables pull-data table-schema table-records)

  setup do
    PhoenixKitSync.enable_system()
    SyncableTable.insert!()
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_sync, :rate_limit_max_wait_seconds)
      Application.delete_env(:phoenix_kit_sync, :rate_limit_wait_budget_seconds)
    end)

    :ok
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp sender(limit) do
    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Peer #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://peer-#{System.unique_integer([:positive])}.example.com",
        "status" => "active",
        "rate_limit_requests_per_minute" => limit
      })

    {connection, token}
  end

  defp rest(action, token) do
    post(build_conn(), "/sync/api/#{action}", %{
      "auth_token_hash" => token_hash(token),
      "table_name" => @table
    })
  end

  defp socket_request(state, connection, event) do
    frame =
      Jason.encode!([
        nil,
        "1",
        "transfer:conn:#{connection.uuid}",
        event,
        %{"table" => @table, "ref" => "r"}
      ])

    case SyncWebsock.handle_in({frame, [opcode: :text]}, state) do
      {:push, {:text, reply}, state} -> {Enum.at(Jason.decode!(reply), 4), state}
      {:ok, state} -> {nil, state}
    end
  end

  # The window is a minute of the wall clock. A test that makes its
  # requests within one starts with at least five seconds of it left.
  defp fresh_window do
    left = 60_000 - rem(System.system_time(:millisecond), 60_000)
    if left < 5_000, do: Process.sleep(left + 50)
  end

  describe "the counter" do
    test "lets exactly the limit through and refuses the next with the seconds left" do
      fresh_window()
      key = "test-#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: assert(:ok = RateLimit.hit(key, 3))

      assert {:error, {:rate_limited, seconds}} = RateLimit.hit(key, 3)
      assert seconds in 1..60
    end

    test "the window frees" do
      key = "test-#{System.unique_integer([:positive])}"
      window_ms = 300
      # Start at the beginning of a window so both hits fall in one.
      Process.sleep(window_ms - rem(System.system_time(:millisecond), window_ms) + 5)

      assert :ok = RateLimit.hit(key, 1, window_ms)
      assert {:error, {:rate_limited, 1}} = RateLimit.hit(key, 1, window_ms)

      Process.sleep(window_ms + 10)
      assert :ok = RateLimit.hit(key, 1, window_ms)
    end

    test "a limit of 0 is no limit" do
      {connection, _token} = sender(0)
      for _ <- 1..50, do: assert(:ok = RateLimit.check(connection))
    end

    test "connections count apart" do
      fresh_window()
      {first, _} = sender(1)
      {second, _} = sender(1)

      assert :ok = RateLimit.check(first)
      assert {:error, {:rate_limited, _}} = RateLimit.check(first)
      assert :ok = RateLimit.check(second)
    end
  end

  describe "every entry point that authorizes a request" do
    test "each REST action answers 429 with Retry-After at the request past the limit" do
      for action <- @rest_actions do
        fresh_window()
        {_connection, token} = sender(2)

        for n <- 1..2 do
          assert json_response(rest(action, token), 200)["success"], "#{action} request #{n}"
        end

        response = rest(action, token)

        assert %{"error_code" => "rate_limited", "retry_after" => seconds} =
                 json_response(response, 429),
               action

        assert [header] = get_resp_header(response, "retry-after")
        assert String.to_integer(header) == seconds
        assert seconds in 1..60
      end
    end

    test "the four actions share one count" do
      fresh_window()
      {_connection, token} = sender(4)

      for action <- @rest_actions, do: assert(json_response(rest(action, token), 200))

      for action <- @rest_actions, do: assert(json_response(rest(action, token), 429))
    end

    test "the socket upgrade answers 429 with Retry-After" do
      fresh_window()
      {_connection, token} = sender(1)
      assert {:ok, _} = Connections.validate_connection(token, "127.0.0.1")

      response =
        build_conn()
        |> put_req_header("upgrade", "websocket")
        |> get("/sync/websocket?token=#{URI.encode_www_form(token)}")

      assert response.status == 429
      assert [seconds] = get_resp_header(response, "retry-after")
      assert String.to_integer(seconds) in 1..60
    end

    test "every request on an open socket counts; the join and heartbeats do not" do
      for event <- ~w(request:tables request:schema request:count request:records) do
        fresh_window()
        {connection, _token} = sender(2)

        {:ok, state} =
          SyncWebsock.init(
            auth_type: :connection,
            connection: connection,
            connection_info: %{remote_ip: "127.0.0.1"}
          )

        {_reply, state} = socket_request(state, connection, "phx_join")

        state =
          Enum.reduce(1..5, state, fn _, state ->
            frame = Jason.encode!([nil, "h", "phoenix", "heartbeat", %{}])
            {:push, _reply, state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
            state
          end)

        {first, state} = socket_request(state, connection, event)
        {second, state} = socket_request(state, connection, event)
        refute first["error"], event
        refute second["error"], event

        {third, _state} = socket_request(state, connection, event)

        assert %{"error_code" => "rate_limited", "retry_after" => seconds, "ref" => "r"} = third,
               event

        assert seconds in 1..60
      end
    end
  end

  describe "the receiver" do
    setup do
      {:ok, connection, _token} =
        Connections.create_connection(%{
          "name" => "Stub sender #{System.unique_integer([:positive])}",
          "direction" => "receiver",
          "status" => "active",
          "site_url" => StubRemote.url()
        })

      %{connection: connection}
    end

    defp recorder do
      test_pid = self()
      fn seconds -> send(test_pid, {:waited, seconds}) end
    end

    test "waits for Retry-After and then pulls the table", %{connection: connection} do
      StubRemote.put_data(@table, [])
      StubRemote.put_rate_limited("pull-data", 1, "1")

      assert {:ok, %{imported: 0, errors: 0}} =
               ConnectionNotifier.pull_table_data(connection, @table, on_rate_limited: recorder())

      assert_received {:waited, 1}
      assert StubRemote.request_count("pull-data") == 2
    end

    test "the table list, a schema and a preview wait the same way", %{connection: connection} do
      StubRemote.put_tables([%{"name" => @table}])

      StubRemote.put_schema(@table, %{
        "table_name" => @table,
        "columns" => [
          %{"column_name" => "id", "data_type" => "bigint", "is_nullable" => "NO"}
        ],
        "primary_key" => ["id"]
      })

      StubRemote.put_data(@table, [%{"id" => 1}])

      for {endpoint, call} <- [
            {"list-tables",
             fn ->
               ConnectionNotifier.fetch_sender_tables(connection, on_rate_limited: recorder())
             end},
            {"table-schema",
             fn ->
               ConnectionNotifier.fetch_table_schema(connection, @table,
                 on_rate_limited: recorder()
               )
             end},
            {"table-records",
             fn ->
               ConnectionNotifier.fetch_table_records(connection, @table,
                 on_rate_limited: recorder()
               )
             end}
          ] do
        StubRemote.put_rate_limited(endpoint, 1, "1")
        assert {:ok, _} = call.(), endpoint
        assert_received {:waited, 1}
        assert StubRemote.request_count(endpoint) == 2, endpoint
      end
    end

    test "a hostile Retry-After is clamped", %{connection: connection} do
      Application.put_env(:phoenix_kit_sync, :rate_limit_max_wait_seconds, 1)
      StubRemote.put_data(@table, [])

      for value <- ["999999999999999999999", "-30", "0", "soon", nil, "1.5"] do
        StubRemote.put_rate_limited("pull-data", 1, value)

        assert {:ok, _} =
                 ConnectionNotifier.pull_table_data(connection, @table,
                   on_rate_limited: recorder()
                 ),
               inspect(value)

        assert_received {:waited, 1}, inspect(value)
      end
    end

    test "stops at the wait budget and fails the table", %{connection: connection} do
      Application.put_env(:phoenix_kit_sync, :rate_limit_max_wait_seconds, 1)
      Application.put_env(:phoenix_kit_sync, :rate_limit_wait_budget_seconds, 2)
      StubRemote.put_data(@table, [])
      StubRemote.put_rate_limited("pull-data", :always, "60")

      assert {:error, :rate_limited} =
               ConnectionNotifier.pull_table_data(connection, @table, on_rate_limited: recorder())

      assert_received {:waited, 1}
      assert_received {:waited, 1}
      refute_received {:waited, _}
      assert StubRemote.request_count("pull-data") == 3

      transfer =
        PhoenixKit.RepoHelper.repo().get_by!(Transfer,
          connection_uuid: connection.uuid,
          table_name: @table
        )

      assert transfer.status == "failed"
    end
  end

  describe "RateLimit.next_wait/2" do
    test "clamps what the peer sends to between 1 s and the maximum" do
      for {value, expected} <- [
            {"30", 30},
            {30, 30},
            {" 7 ", 7},
            {"999999999999999999999999", 60},
            {10_000_000, 60},
            {"-5", 1},
            {-5, 1},
            {"0", 1},
            {"soon", 5},
            {"Wed, 21 Oct 2026 07:28:00 GMT", 5},
            {nil, 5},
            {1.5, 5},
            {%{"a" => 1}, 5}
          ] do
        assert RateLimit.next_wait(value) == {:wait, expected}, inspect(value)
      end
    end

    test "gives up when the wait would pass the budget" do
      assert {:wait, 60} = RateLimit.next_wait("60", 240)
      assert :give_up = RateLimit.next_wait("60", 241)
      assert :give_up = RateLimit.next_wait("1", 300)
    end
  end

  describe "WebSocketClient" do
    setup do
      {:ok,
       state: %WebSocketClient{
         url: "ws://example.com",
         code: "ABCD2345",
         caller: self(),
         receiver_info: %{},
         ref_counter: 1,
         pending_refs: %{"1" => :tables},
         requests: %{"1" => %{msg: "the request frame", waited: 0}},
         joined: true,
         heartbeat_ref: nil
       }}
    end

    defp rate_limited_frame(retry_after) do
      Jason.encode!([
        nil,
        nil,
        "transfer:ABCD2345",
        "response:error",
        %{
          "error" => "Too many",
          "error_code" => "rate_limited",
          "retry_after" => retry_after,
          "ref" => "1"
        }
      ])
    end

    test "sends the same request again after the sender's wait", %{state: state} do
      assert {:ok, state} = WebSocketClient.handle_frame({:text, rate_limited_frame(1)}, state)
      assert_received {:sync_client, {:rate_limited, :tables, 1}}
      refute_received {:sync_client, {:request_error, _, _}}

      assert_receive {:retry_request, "1"}, 1_500

      assert {:reply, {:text, "the request frame"}, _state} =
               WebSocketClient.handle_info({:retry_request, "1"}, state)
    end

    test "clamps a hostile wait and gives up past the budget", %{state: state} do
      Application.put_env(:phoenix_kit_sync, :rate_limit_wait_budget_seconds, 70)

      assert {:ok, state} =
               WebSocketClient.handle_frame({:text, rate_limited_frame(10 ** 12)}, state)

      assert_received {:sync_client, {:rate_limited, :tables, 60}}

      assert {:ok, state} = WebSocketClient.handle_frame({:text, rate_limited_frame(60)}, state)
      assert_received {:sync_client, {:request_error, :tables, :rate_limited}}
      assert state.pending_refs == %{}
    end
  end
end
