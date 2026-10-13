defmodule PhoenixKitSync.Integration.WsKeysetPagingTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Client
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.Test.Repo, as: TestRepo
  alias PhoenixKitSync.Web.SyncWebsock
  alias PhoenixKitSync.WebSocketClient

  # `request:records` over the WebSocket continues by key when the receiver
  # sends back the position the sender answered ("next_after" → "after"),
  # so rows written between two pages neither hide a row nor repeat one.
  # Either side may be from before positions: a request without "after" is
  # cut by its offset, and a reply without "next_after" is followed by
  # offset.

  @table "wk_rows"

  setup do
    Sandbox.mode(TestRepo, {:shared, self()})
    PhoenixKitSync.enable_system()

    repo().query!("CREATE TABLE #{@table} (id int PRIMARY KEY, label text)")
    repo().query!("INSERT INTO #{@table} SELECT g, 'row ' || g FROM generate_series(1, 10) g")

    {:ok, session} = PhoenixKitSync.create_session(:send)
    {:ok, state} = SyncWebsock.init(auth_type: :session, code: session.code, session: session)

    {:ok, state: %{state | joined: true}, session: session}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp request(state, table, extra) do
    payload = Map.merge(%{"table" => table, "ref" => "r", "limit" => 3}, extra)
    frame = Jason.encode!([nil, "r", "transfer:#{state.code}", "request:records", payload])

    {:push, {:text, json}, _state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
    [_join_ref, _ref, _topic, event, reply] = Jason.decode!(json)
    {event, reply}
  end

  defp ids(reply), do: Enum.map(reply["records"], & &1["id"])

  describe "the sender" do
    test "names the position after each page", %{state: state} do
      assert {"response:records", reply} = request(state, @table, %{})

      assert ids(reply) == [1, 2, 3]
      assert reply["next_after"] == %{"id" => "3"}
      # What a receiver from before positions reads is all still there.
      assert %{"offset" => 0, "has_more" => true, "ref" => "r"} = reply
    end

    test "answers the rows after a position, whatever the offset says", %{state: state} do
      assert {"response:records", reply} =
               request(state, @table, %{"after" => %{"id" => "3"}, "offset" => 7})

      assert ids(reply) == [4, 5, 6]
      assert reply["next_after"] == %{"id" => "6"}
    end

    test "rows deleted or inserted before the position do not shift the next page", %{
      state: state
    } do
      {"response:records", first} = request(state, @table, %{})
      assert ids(first) == [1, 2, 3]

      repo().query!("DELETE FROM #{@table} WHERE id IN (1, 2)")
      repo().query!("INSERT INTO #{@table} VALUES (0, 'late')")

      {"response:records", by_key} = request(state, @table, %{"after" => first["next_after"]})
      assert ids(by_key) == [4, 5, 6]

      # A receiver that sends no position is cut by offset, as it always
      # was: here that hides row 4.
      {"response:records", by_offset} = request(state, @table, %{"offset" => 3})
      assert ids(by_offset) == [5, 6, 7]
    end

    test "the position follows to the end of the table, each row once", %{state: state} do
      pages =
        Stream.unfold(%{}, fn
          :done ->
            nil

          extra ->
            {"response:records", reply} = request(state, @table, extra)

            case reply do
              %{"records" => []} -> {reply, :done}
              %{"next_after" => position} -> {reply, %{"after" => position}}
            end
        end)
        |> Enum.to_list()

      assert Enum.flat_map(pages, &ids/1) == Enum.to_list(1..10)
      refute Map.has_key?(List.last(pages), "next_after")
    end

    test "a composite key continues inside and across its first column", %{state: state} do
      repo().query!("CREATE TABLE wk_pairs (a int, b text, PRIMARY KEY (a, b))")

      repo().query!(
        "INSERT INTO wk_pairs SELECT a, 'b' || b FROM generate_series(1, 2) a, generate_series(1, 4) b"
      )

      {"response:records", first} = request(state, "wk_pairs", %{})
      assert first["next_after"] == %{"a" => "1", "b" => "b3"}

      {"response:records", second} = request(state, "wk_pairs", %{"after" => first["next_after"]})
      assert Enum.map(second["records"], &{&1["a"], &1["b"]}) == [{1, "b4"}, {2, "b1"}, {2, "b2"}]
    end

    test "a key no cursor continues from gets no position, and none is taken", %{state: state} do
      repo().query!("CREATE TYPE wk_mood AS ENUM ('low', 'mid', 'high', 'top')")
      repo().query!("CREATE TABLE wk_moods (mood wk_mood PRIMARY KEY)")
      repo().query!("INSERT INTO wk_moods SELECT unnest(enum_range(NULL::wk_mood))")

      assert {"response:records", reply} = request(state, "wk_moods", %{})
      assert length(reply["records"]) == 3
      refute Map.has_key?(reply, "next_after")

      # Paged by offset, as before.
      assert {"response:records", %{"records" => [%{"mood" => "top"}]}} =
               request(state, "wk_moods", %{"offset" => 3})

      assert {"response:error", %{"error" => error, "ref" => "r"}} =
               request(state, "wk_moods", %{"after" => %{"mood" => "mid"}})

      assert error == PhoenixKitSync.Errors.message(:invalid_cursor)
    end

    @bad_positions [
      {"a string", "3"},
      {"a number", 3},
      {"a list", [3]},
      {"an empty map", %{}},
      {"another column", %{"label" => "row 3"}},
      {"an extra column", %{"id" => "3", "label" => "row 3"}},
      {"a value that is no integer", %{"id" => "three"}},
      {"SQL in the value", %{"id" => "3; DROP TABLE wk_rows"}},
      {"a nested value", %{"id" => %{"x" => 1}}}
    ]

    for {label, position} <- @bad_positions do
      test "#{label} for a position is answered as an error", %{state: state} do
        assert {"response:error", %{"error" => error, "ref" => "r"}} =
                 request(state, @table, %{"after" => unquote(Macro.escape(position))})

        assert error == PhoenixKitSync.Errors.message(:invalid_cursor)
        assert %{rows: [[10]]} = repo().query!("SELECT count(*) FROM #{@table}")
      end
    end

    test "an integer in the position reads as its text", %{state: state} do
      assert {"response:records", reply} = request(state, @table, %{"after" => %{"id" => 8}})
      assert ids(reply) == [9, 10]
    end
  end

  describe "DataExporter.fetch_page/2" do
    test "a position is refused under an order that is not the key's" do
      assert {:error, :invalid_cursor} =
               DataExporter.fetch_page(@table, order_by: "label", after: %{"id" => "3"})

      assert {:ok, %{records: [_ | _], next_after: nil}} =
               DataExporter.fetch_page(@table, order_by: "label", limit: 3)
    end

    test "stream_records/2 does not lose a row to one deleted behind it" do
      {:ok, stream} = DataExporter.stream_records(@table, batch_size: 3)

      # The stream is lazy: the delete lands between its first two batches.
      ids =
        stream
        |> Stream.each(fn [first | _] ->
          if first["id"] == 1, do: repo().query!("DELETE FROM #{@table} WHERE id = 2")
        end)
        |> Enum.flat_map(fn batch -> Enum.map(batch, & &1["id"]) end)

      assert ids == Enum.to_list(1..10)
    end

    test "fetch_records/2 takes the same position" do
      assert {:ok, [%{"id" => 4}, %{"id" => 5}]} =
               DataExporter.fetch_records(@table, after: %{"id" => "3"}, limit: 2)
    end
  end

  describe "the client" do
    # Answers Client's casts the way WebSocketClient relays a sender's
    # replies, and reports each request it got.
    defp fake_sender(test_pid, reply_for) do
      spawn_link(fn -> fake_sender_loop(test_pid, reply_for) end)
    end

    defp fake_sender_loop(test_pid, reply_for) do
      receive do
        {:"$websockex_cast", {:request_schema, table}} ->
          send(test_pid, {:sync_client, {:schema, table, %{}}})

        {:"$websockex_cast", {:request_records, table, opts}} ->
          send(test_pid, {:requested, opts})
          send(test_pid, {:sync_client, {:records, table, reply_for.(opts)}})
      end

      fake_sender_loop(test_pid, reply_for)
    end

    defp requests(acc \\ []) do
      receive do
        {:requested, opts} -> requests([{opts[:offset], opts[:after]} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp page(opts) do
      {:ok, records} = DataExporter.fetch_records(@table, offset: opts[:offset], limit: 4)
      %{records: records, offset: opts[:offset], has_more: records != []}
    end

    test "sends back the position a sender answers" do
      sender =
        fake_sender(self(), fn opts ->
          {:ok, page} = DataExporter.fetch_page(@table, after: opts[:after], limit: 4)
          Map.merge(page, %{offset: opts[:offset], has_more: page.records != []})
        end)

      assert {:ok, %{updated: 10}} = Client.transfer(sender, @table, strategy: :overwrite)

      assert requests() == [
               {0, nil},
               {4, %{"id" => "4"}},
               {8, %{"id" => "8"}},
               {10, %{"id" => "10"}}
             ]
    end

    test "follows a sender that answers no position by offset alone" do
      sender = fake_sender(self(), &page/1)

      assert {:ok, %{updated: 10}} = Client.transfer(sender, @table, strategy: :overwrite)
      assert requests() == [{0, nil}, {4, nil}, {8, nil}, {10, nil}]
    end

    test "drops a position once the sender stops answering one" do
      sender =
        fake_sender(self(), fn opts ->
          if opts[:offset] == 0,
            do: Map.put(page(opts), :next_after, %{"id" => "4"}),
            else: page(opts)
        end)

      assert {:ok, %{updated: 10}} = Client.transfer(sender, @table, strategy: :overwrite)
      assert requests() == [{0, nil}, {4, %{"id" => "4"}}, {8, nil}, {10, nil}]
    end
  end

  describe "WebSocketClient" do
    setup do
      {:ok,
       client: %WebSocketClient{
         url: "ws://example.com",
         code: "ABCD2345",
         caller: self(),
         receiver_info: %{},
         ref_counter: 0,
         pending_refs: %{},
         joined: true,
         heartbeat_ref: nil
       }}
    end

    defp sent_payload({:reply, {:text, json}, state}) do
      [_join_ref, _ref, _topic, "request:records", payload] = Jason.decode!(json)
      {payload, state}
    end

    test "a request carries the position beside the offset, and no key without one", %{
      client: client
    } do
      {payload, _state} =
        client
        |> then(
          &WebSocketClient.handle_cast(
            {:request_records, @table, [offset: 4, limit: 2, after: %{"id" => "4"}]},
            &1
          )
        )
        |> sent_payload()

      assert %{"after" => %{"id" => "4"}, "offset" => 4, "limit" => 2} = payload

      for opts <- [[offset: 4, limit: 2], [offset: 4, limit: 2, after: nil]] do
        {payload, _state} =
          {:request_records, @table, opts}
          |> WebSocketClient.handle_cast(client)
          |> sent_payload()

        refute Map.has_key?(payload, "after")
        assert payload["offset"] == 4
      end
    end

    defp relay(client, reply) do
      {_payload, client} =
        {:request_records, @table, []} |> WebSocketClient.handle_cast(client) |> sent_payload()

      frame =
        Jason.encode!([
          nil,
          nil,
          "transfer:ABCD2345",
          "response:records",
          Map.put(reply, "ref", "1")
        ])

      assert {:ok, _client} = WebSocketClient.handle_frame({:text, frame}, client)
      assert_received {:sync_client, {:records, @table, result}}
      result
    end

    test "a reply's position reaches the caller", %{client: client} do
      result = relay(client, %{"records" => [%{"id" => 1}], "next_after" => %{"id" => "1"}})
      assert result.next_after == %{"id" => "1"}
    end

    test "a reply without one reads as none", %{client: client} do
      assert relay(client, %{"records" => [%{"id" => 1}]}).next_after == nil
    end

    for {label, position} <- [
          {"a string", "1"},
          {"a list", [1]},
          {"an empty map", %{}},
          {"a nested value", %{"id" => %{"x" => 1}}},
          {"a null value", %{"id" => nil}}
        ] do
      test "#{label} for a position is not passed on", %{client: client} do
        reply = %{"records" => [%{"id" => 1}], "next_after" => unquote(Macro.escape(position))}
        assert relay(client, reply).next_after == nil
      end
    end
  end

  describe "a transfer while rows are deleted" do
    # This module's client against this module's sender over a real socket.
    # :overwrite writes every pulled row back onto itself and a trigger
    # counts the writes; the write of the page's last row deletes two rows
    # the transfer has already passed, which is what shifts an offset.
    setup do
      repo().query!("CREATE TABLE wk_live (id int PRIMARY KEY, writes int NOT NULL DEFAULT 0)")

      repo().query!("INSERT INTO wk_live (id) SELECT generate_series(1, 30)")

      repo().query!("""
      CREATE FUNCTION wk_live_write() RETURNS trigger AS $$
      BEGIN
        NEW.writes := OLD.writes + 1;
        IF NEW.id = 10 THEN
          DELETE FROM wk_live WHERE id IN (1, 2);
        END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """)

      repo().query!(
        "CREATE TRIGGER wk_live_writes BEFORE UPDATE ON wk_live " <>
          "FOR EACH ROW EXECUTE FUNCTION wk_live_write()"
      )

      :ok
    end

    test "every row left is pulled exactly once", %{session: session} do
      port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)
      {:ok, client} = Client.connect("ws://localhost:#{port}", session.code)
      on_exit(fn -> Client.disconnect(client) end)

      assert {:ok, result} =
               Client.transfer(client, "wk_live", strategy: :overwrite, batch_size: 10)

      assert result.errors == []

      %{rows: rows} = repo().query!("SELECT writes, count(*) FROM wk_live GROUP BY writes")
      # 28 rows are left; paged by offset, rows 11 and 12 would have 0 writes.
      assert Map.new(rows, &List.to_tuple/1) == %{1 => 28}
    end
  end
end
