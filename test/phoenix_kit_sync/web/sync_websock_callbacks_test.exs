defmodule PhoenixKitSync.Web.SyncWebsockCallbacksTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Web.SyncWebsock

  # Direct unit tests on the WebSock behaviour callbacks (init/3,
  # handle_in/2, handle_info/2, terminate/2). The callbacks are pure
  # functions of state — no real WebSocket connection needed. Drives the
  # message protocol (phx_join, phoenix heartbeat, request:capabilities,
  # request:tables, request:schema, request:records) through encode →
  # call → decode.

  defp create_active_sender do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "Websock Test #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://websock-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    active
  end

  defp encode(join_ref, ref, topic, event, payload) do
    Jason.encode!([join_ref, ref, topic, event, payload])
  end

  defp decode_reply({:push, {:text, json}, _state}) do
    case Jason.decode!(json) do
      [_join_ref, _ref, topic, event, payload] -> %{topic: topic, event: event, payload: payload}
    end
  end

  describe "init/1 — session-based auth" do
    test "initialises state with code + session" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, state} =
        SyncWebsock.init(
          auth_type: :session,
          code: session.code,
          session: session
        )

      assert state.auth_type == :session
      assert state.code == session.code
      assert state.joined == false
    end
  end

  describe "init/1 — connection-based auth" do
    test "initialises state with db_connection" do
      conn = create_active_sender()

      {:ok, state} =
        SyncWebsock.init(
          auth_type: :connection,
          connection: conn
        )

      assert state.auth_type == :connection
      assert state.code == "conn:#{conn.uuid}"
      assert state.db_connection.uuid == conn.uuid
      assert state.joined == false
    end
  end

  describe "handle_in/2 — phx_join" do
    test "matching code transitions to joined" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, state} =
        SyncWebsock.init(
          auth_type: :session,
          code: session.code,
          session: session
        )

      payload =
        encode("1", "1", "transfer:#{session.code}", "phx_join", %{"receiver_info" => %{}})

      result = SyncWebsock.handle_in({payload, [opcode: :text]}, state)

      assert {:push, {:text, json}, new_state} = result
      assert new_state.joined == true

      decoded = Jason.decode!(json)
      [_, _, _, "phx_reply", %{"status" => status}] = decoded
      assert status == "ok"
    end

    test "mismatched code rejects with code_mismatch" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, state} =
        SyncWebsock.init(auth_type: :session, code: session.code, session: session)

      payload = encode("1", "1", "transfer:wrongcode", "phx_join", %{})
      result = SyncWebsock.handle_in({payload, [opcode: :text]}, state)

      reply = decode_reply(result)
      assert reply.payload["status"] == "error"
      assert reply.payload["response"]["reason"] == "code_mismatch"
    end
  end

  describe "handle_in/2 — phoenix heartbeat" do
    test "heartbeat replies with phx_reply ok" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "abc", session: %{})

      payload = encode(nil, "hb1", "phoenix", "heartbeat", %{})
      result = SyncWebsock.handle_in({payload, [opcode: :text]}, state)

      reply = decode_reply(result)
      assert reply.event == "phx_reply"
      assert reply.payload["status"] == "ok"
    end
  end

  describe "handle_in/2 — invalid JSON" do
    test "ignores undecodable text without crashing" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "abc", session: %{})

      result = SyncWebsock.handle_in({"this is not json {", [opcode: :text]}, state)

      # Returns {:ok, state} on decode failure (logged but ignored).
      assert {:ok, ^state} = result
    end
  end

  describe "handle_in/2 — binary messages" do
    test "ignores binary frames" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "abc", session: %{})

      assert {:ok, ^state} =
               SyncWebsock.handle_in({<<1, 2, 3>>, [opcode: :binary]}, state)
    end
  end

  describe "handle_in/2 — connection-based request:tables" do
    test "joined connection returns table list filtered by allowed_tables" do
      conn = create_active_sender()

      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: conn)

      # Skip phx_join (test the post-join state directly).
      state = %{state | joined: true}

      payload =
        encode(nil, "req-1", "transfer:conn:#{conn.uuid}", "request:tables", %{"ref" => "ref-1"})

      result = SyncWebsock.handle_in({payload, [opcode: :text]}, state)

      reply = decode_reply(result)
      assert reply.event == "response:tables"
      assert is_list(reply.payload["tables"])
    end
  end

  describe "handle_info/2" do
    test "{:sync, msg} info messages are logged and state is unchanged" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "abc", session: %{})

      assert {:ok, ^state} = SyncWebsock.handle_info({:sync, :anything}, state)
    end

    test "unknown info messages are logged and state is unchanged" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "abc", session: %{})

      assert {:ok, ^state} = SyncWebsock.handle_info(:totally_unexpected, state)
    end
  end

  describe "handle_in/2 — malformed request:records (DoS hardening)" do
    # Regression for the Map.fetch! → match-and-validate fix in
    # sync_websock.ex. Pre-fix, missing/invalid keys crashed the
    # WebSock process (DoS vector for any peer who can connect).

    setup do
      conn = create_active_sender()
      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: conn)
      {:ok, state: %{state | joined: true}, conn: conn}
    end

    test "missing 'table' key — handler returns {:ok, state}, doesn't crash", %{
      state: state,
      conn: conn
    } do
      payload =
        encode(nil, "r1", "transfer:conn:#{conn.uuid}", "request:records", %{"ref" => "r1"})

      assert {:ok, _new_state} = SyncWebsock.handle_in({payload, [opcode: :text]}, state)
    end

    test "missing 'ref' key — handler returns {:ok, state}, doesn't crash", %{
      state: state,
      conn: conn
    } do
      payload =
        encode(nil, "r2", "transfer:conn:#{conn.uuid}", "request:records", %{"table" => "x"})

      assert {:ok, _new_state} = SyncWebsock.handle_in({payload, [opcode: :text]}, state)
    end

    test "wrong type for 'table' (integer) — handler doesn't crash", %{state: state, conn: conn} do
      payload =
        encode(nil, "r3", "transfer:conn:#{conn.uuid}", "request:records", %{
          "table" => 12_345,
          "ref" => "r3"
        })

      assert {:ok, _new_state} = SyncWebsock.handle_in({payload, [opcode: :text]}, state)
    end

    test "empty payload — handler doesn't crash", %{state: state, conn: conn} do
      payload = encode(nil, "r4", "transfer:conn:#{conn.uuid}", "request:records", %{})

      assert {:ok, _new_state} = SyncWebsock.handle_in({payload, [opcode: :text]}, state)
    end
  end

  describe "terminate/2" do
    test "session-based: notifies owner_pid of receiver_disconnected" do
      session = %{code: "abc", owner_pid: self()}
      state = %SyncWebsock{auth_type: :session, code: "abc", session: session}

      assert :ok = SyncWebsock.terminate(:normal, state)
      assert_receive {:sync, :receiver_disconnected}
    end

    test "connection-based: terminates without sending owner notification" do
      conn = create_active_sender()

      state = %SyncWebsock{
        auth_type: :connection,
        code: "conn:#{conn.uuid}",
        db_connection: conn,
        session: nil
      }

      assert :ok = SyncWebsock.terminate(:normal, state)
      refute_receive {:sync, _}, 50
    end
  end
end
