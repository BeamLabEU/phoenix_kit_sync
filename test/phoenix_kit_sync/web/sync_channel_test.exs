defmodule PhoenixKitSync.Web.SyncChannelTest do
  use PhoenixKitSync.ChannelCase

  alias PhoenixKitSync.Web.SyncChannel
  alias PhoenixKitSync.Web.SyncSocket

  setup do
    PhoenixKitSync.enable_system()
    {:ok, session} = PhoenixKitSync.create_session(:send)
    {:ok, socket} = connect(SyncSocket, %{"code" => session.code})

    {:ok, socket: socket, session: session}
  end

  describe "join/3" do
    test "accepts join when topic matches session code", %{socket: socket, session: session} do
      assert {:ok, _reply, _channel_socket} =
               subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")
    end

    test "rejects with code_mismatch when topic doesn't match", %{socket: socket} do
      assert {:error, %{reason: "code_mismatch"}} =
               subscribe_and_join(socket, SyncChannel, "transfer:OTHERCOD")
    end
  end

  describe "request:capabilities" do
    test "responds with version + features", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "cap-1"
      push(channel, "request:capabilities", %{"ref" => ref})

      assert_push("response:capabilities", %{capabilities: caps, ref: ^ref})
      assert is_binary(caps.version)
      assert "list_tables" in caps.features
    end
  end

  # These replies are served by a live Postgres introspection query, so the
  # default 100 ms assert_push deadline loses the race on a loaded machine and
  # reports an empty mailbox as a protocol failure.
  @reply_timeout 2_000

  describe "request:tables" do
    test "responds with the table list", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "tab-1"
      push(channel, "request:tables", %{"ref" => ref})

      assert_push("response:tables", %{tables: tables, ref: ^ref}, @reply_timeout)
      assert is_list(tables)
    end
  end

  describe "request:schema" do
    test "responds with schema for known table", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "sch-1"
      push(channel, "request:schema", %{"table" => "phoenix_kit_sync_connections", "ref" => ref})

      assert_push("response:schema", %{schema: schema, ref: ^ref}, @reply_timeout)
      assert is_list(schema.columns) or is_map(schema)
    end

    test "responds with response:error for unknown table", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "sch-2"
      push(channel, "request:schema", %{"table" => "nonexistent_table_zz", "ref" => ref})

      assert_push("response:error", %{error: msg, ref: ^ref}, @reply_timeout)
      assert msg =~ "not found"
    end
  end

  describe "request:count" do
    test "responds with record count", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "cnt-1"
      push(channel, "request:count", %{"table" => "phoenix_kit_sync_connections", "ref" => ref})

      assert_push("response:count", %{count: count, ref: ^ref}, @reply_timeout)
      assert is_integer(count)
    end
  end

  describe "request:records" do
    test "responds with paginated records", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = "rec-1"

      push(channel, "request:records", %{
        "table" => "phoenix_kit_sync_connections",
        "ref" => ref,
        "limit" => 10
      })

      assert_push(
        "response:records",
        %{records: records, ref: ^ref, has_more: has_more},
        @reply_timeout
      )

      assert is_list(records)
      assert is_boolean(has_more)
    end
  end

  describe "request:records — a table with uuid columns" do
    # The channel serializer JSON-encodes every push on a live socket; the
    # test transport does not, so the payload is encoded here the same way.
    test "the reply payload encodes as JSON", %{socket: socket, session: session} do
      {:ok, _connection, _token} =
        PhoenixKitSync.Connections.create_connection(%{
          "name" => "Channel uuid #{System.unique_integer([:positive])}",
          "direction" => "sender",
          "site_url" => "https://channel-uuid-#{System.unique_integer([:positive])}.example.com"
        })

      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "phoenix_kit_sync_connections",
        "ref" => "uuid-json"
      })

      assert_push(
        "response:records",
        %{ref: "uuid-json", records: [_ | _]} = payload,
        @reply_timeout
      )

      assert {:ok, _json} = Jason.encode(payload)
    end
  end

  describe "request:records — malformed payload (DoS hardening)" do
    # Pre-fix sync_channel.ex used Map.fetch! on the "table" and "ref"
    # keys; missing keys crashed the channel and triggered a reconnect
    # loop. Post-fix returns a structured error reply.

    test "missing 'table' replies with structured error, doesn't crash", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = push(channel, "request:records", %{"ref" => "missing-table-1"})
      assert_reply(ref, :error, %{reason: "missing_fields"})
      assert Process.alive?(channel.channel_pid)
    end

    test "missing 'ref' replies with structured error, doesn't crash", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = push(channel, "request:records", %{"table" => "phoenix_kit_sync_connections"})
      assert_reply(ref, :error, %{reason: "missing_fields"})
      assert Process.alive?(channel.channel_pid)
    end

    test "wrong type for 'table' (integer) replies with error, doesn't crash", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = push(channel, "request:records", %{"table" => 12_345, "ref" => "bad-type"})
      assert_reply(ref, :error, %{reason: "missing_fields"})
      assert Process.alive?(channel.channel_pid)
    end

    test "empty payload replies with error, doesn't crash", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = push(channel, "request:records", %{})
      assert_reply(ref, :error, %{reason: "missing_fields"})
      assert Process.alive?(channel.channel_pid)
    end
  end

  describe "unknown events" do
    test "replies with :error for unknown event", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      ref = push(channel, "request:made_up", %{})
      assert_reply(ref, :error, %{message: msg})
      assert msg =~ "Unknown event"
    end
  end
end
