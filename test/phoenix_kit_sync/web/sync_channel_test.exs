defmodule PhoenixKitSync.Web.SyncChannelTest do
  use PhoenixKitSync.ChannelCase

  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V2.JSONSerializer
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

  # These replies are served by live Postgres queries (the table list counts
  # the rows of every table), so the default 100 ms assert_push deadline
  # loses the race on a loaded machine and reports an empty mailbox as a
  # protocol failure. The deadline is only how long a missing reply takes to
  # fail: a reply that arrives ends the wait at once.
  @reply_timeout 15_000

  test "a session cannot request token-table schema, counts, or records", %{
    socket: socket,
    session: session
  } do
    {:ok, _reply, channel} =
      subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

    for event <- ["schema", "count", "records"] do
      ref = "excluded-#{event}"
      push(channel, "request:#{event}", %{"table" => "phoenix_kit_users_tokens", "ref" => ref})

      assert_push("response:error", %{error: message, ref: ^ref}, @reply_timeout)
      assert message =~ "table_excluded"
    end
  end

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
      push(channel, "request:schema", %{"table" => "phoenix_kit_staff_skills", "ref" => ref})

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
      push(channel, "request:count", %{"table" => "phoenix_kit_staff_skills", "ref" => ref})

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
        "table" => "phoenix_kit_staff_skills",
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
    # A live socket hands every push to its serializer, which JSON-encodes
    # it; the test transport delivers the message as is, so the test runs
    # the pushed message through the same serializer.
    test "the reply encodes through the socket's JSON serializer", %{
      socket: socket,
      session: session
    } do
      PhoenixKitSync.SyncableTable.insert!()

      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "phoenix_kit_staff_skills",
        "ref" => "uuid-json"
      })

      assert_receive %Message{
                       event: "response:records",
                       payload: %{ref: "uuid-json", records: [_ | _]}
                     } = message,
                     @reply_timeout

      assert {:socket_push, :text, json} = JSONSerializer.encode!(message)

      assert [_join_ref, _ref, _topic, "response:records", %{"records" => [record | _]}] =
               Jason.decode!(json)

      assert {:ok, _} = Ecto.UUID.cast(record["uuid"])
    end
  end

  describe "request:records — offset and limit from the peer" do
    for {label, extra} <- [
          {"non-numeric", %{"offset" => "abc", "limit" => "x"}},
          {"negative", %{"offset" => -5, "limit" => -1}}
        ] do
      test "#{label} values fall back instead of failing", %{socket: socket, session: session} do
        {:ok, _reply, channel} =
          subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

        push(
          channel,
          "request:records",
          Map.merge(
            %{"table" => "phoenix_kit_staff_skills", "ref" => "bounded"},
            unquote(Macro.escape(extra))
          )
        )

        assert_push("response:records", %{ref: "bounded", offset: offset}, @reply_timeout)
        assert offset == 0
      end
    end
  end

  describe "request:records — offset and limit above the caps" do
    setup do
      # One row more than DataExporter returns in one call.
      PhoenixKit.RepoHelper.repo().query!("CREATE TABLE ch_bounded (id int PRIMARY KEY)")

      PhoenixKit.RepoHelper.repo().query!(
        "INSERT INTO ch_bounded SELECT generate_series(1, 1001)"
      )

      :ok
    end

    test "a huge offset is clamped to the cap", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "ch_bounded",
        "ref" => "huge-offset",
        "offset" => 1_000_000_000_000_000_000_000_000_000
      })

      assert_push(
        "response:records",
        %{ref: "huge-offset", offset: offset, records: []},
        @reply_timeout
      )

      assert offset == PhoenixKitSync.Params.max_offset()
    end

    test "a limit above the export cap still reports more records", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "ch_bounded",
        "ref" => "big-limit",
        "limit" => 5_000
      })

      assert_push(
        "response:records",
        %{ref: "big-limit", records: records, has_more: has_more},
        @reply_timeout
      )

      # Uncapped, the 1000 rows DataExporter returns fall short of the
      # requested 5000 and the receiver stops one row early.
      assert length(records) == PhoenixKitSync.DataExporter.max_limit()
      assert has_more
    end
  end

  describe "request:records — paging by key" do
    setup do
      PhoenixKit.RepoHelper.repo().query!("CREATE TABLE ch_keyed (id int PRIMARY KEY)")
      PhoenixKit.RepoHelper.repo().query!("INSERT INTO ch_keyed SELECT generate_series(1, 7)")
      :ok
    end

    test "a page names the position after it, and a request with it continues there", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{"table" => "ch_keyed", "ref" => "k1", "limit" => 3})

      assert_push(
        "response:records",
        %{ref: "k1", records: first, next_after: position, offset: 0},
        @reply_timeout
      )

      assert Enum.map(first, & &1["id"]) == [1, 2, 3]
      assert position == %{"id" => "3"}

      # A row before the position goes: by offset the next page would
      # start at 5.
      PhoenixKit.RepoHelper.repo().query!("DELETE FROM ch_keyed WHERE id = 1")

      push(channel, "request:records", %{
        "table" => "ch_keyed",
        "ref" => "k2",
        "limit" => 3,
        "offset" => 3,
        "after" => position
      })

      assert_push("response:records", %{ref: "k2", records: second}, @reply_timeout)
      assert Enum.map(second, & &1["id"]) == [4, 5, 6]
    end

    test "a request without a position is cut by its offset, as before", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "ch_keyed",
        "ref" => "k3",
        "limit" => 3,
        "offset" => 5
      })

      assert_push("response:records", %{ref: "k3", records: records, offset: 5}, @reply_timeout)
      assert Enum.map(records, & &1["id"]) == [6, 7]
    end

    test "an empty page names no position", %{socket: socket, session: session} do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      push(channel, "request:records", %{
        "table" => "ch_keyed",
        "ref" => "k4",
        "after" => %{"id" => "7"}
      })

      assert_push("response:records", %{ref: "k4", records: []} = reply, @reply_timeout)
      refute Map.has_key?(reply, :next_after)
    end

    test "a position that does not fit the key is an error reply", %{
      socket: socket,
      session: session
    } do
      {:ok, _reply, channel} =
        subscribe_and_join(socket, SyncChannel, "transfer:#{session.code}")

      for {ref, position} <- [{"b1", "3"}, {"b2", %{"nope" => "3"}}, {"b3", %{"id" => "x"}}] do
        push(channel, "request:records", %{
          "table" => "ch_keyed",
          "ref" => ref,
          "after" => position
        })

        assert_push("response:error", %{ref: ^ref, error: error}, @reply_timeout)
        assert error =~ "invalid_cursor"
      end
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

      ref = push(channel, "request:records", %{"table" => "phoenix_kit_staff_skills"})
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
