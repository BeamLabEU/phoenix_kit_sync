defmodule PhoenixKitSync.Integration.UntrustedNamesAndShapesTest do
  use PhoenixKitSync.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.ConnectionNotifier.Prepare
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.PullCursor
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Web.SyncWebsock
  alias PhoenixKitSync.WebSocketClient
  alias PhoenixKitSync.Workers.ImportWorker

  # Names and answers that come from the other site, in the spellings and
  # shapes a hostile or broken one can give them.

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp table_exists?(name) do
    repo().query!("SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = $1", [name]).num_rows ==
      1
  end

  # ===========================================
  # The never-synced tables, however they are spelled
  # ===========================================

  describe "a never-synced table under another spelling" do
    @spellings [
      # the list
      "PHOENIX_KIT_SETTINGS",
      "Phoenix_Kit_Sync_Connections",
      "SCHEMA_MIGRATIONS",
      # the prefixes
      "OBAN_JOBS",
      "Oban_Anything",
      "PG_CLASS",
      # the name parts
      "API_TOKENS",
      "Web_Sessions"
    ]

    for name <- @spellings do
      test "#{name} is excluded" do
        assert SchemaInspector.excluded_table?(unquote(name))
      end
    end

    test "a table the host names is excluded in any case" do
      Application.put_env(:phoenix_kit_sync, :excluded_tables, ["My_App_Clients"])
      on_exit(fn -> Application.delete_env(:phoenix_kit_sync, :excluded_tables) end)

      for name <- ["my_app_clients", "MY_APP_CLIENTS", "My_App_Clients"] do
        assert SchemaInspector.excluded_table?(name), name
      end

      refute SchemaInspector.excluded_table?("my_app_orders")
    end

    test "a real quoted table of that name is not listed, read or written" do
      repo().query!(~s[CREATE TABLE "PHOENIX_KIT_SETTINGS" (id bigint PRIMARY KEY, value text)])
      repo().query!(~s[INSERT INTO "PHOENIX_KIT_SETTINGS" VALUES (1, 'incoming password')])

      {:ok, tables} = SchemaInspector.list_tables()
      refute "PHOENIX_KIT_SETTINGS" in Enum.map(tables, & &1.name)

      assert {:error, :table_excluded} = SchemaInspector.get_schema("PHOENIX_KIT_SETTINGS")
      assert {:error, :table_excluded} = DataExporter.fetch_records("PHOENIX_KIT_SETTINGS")
      assert {:error, :table_excluded} = DataExporter.get_count("PHOENIX_KIT_SETTINGS")

      assert {:error, :table_excluded} =
               DataImporter.import_records(
                 "PHOENIX_KIT_SETTINGS",
                 [%{"id" => 2, "value" => "x"}],
                 :skip
               )

      assert repo().query!(~s[SELECT count(*) FROM "PHOENIX_KIT_SETTINGS"]).rows == [[1]]
    end
  end

  # ===========================================
  # create_table/3
  # ===========================================

  describe "SchemaInspector.create_table/3" do
    @schema %{
      "columns" => [%{"name" => "id", "type" => "bigint", "nullable" => false}],
      "primary_key" => ["id"]
    }

    for name <- ["shop_webhook_secrets", "partner_api_keys", "OBAN_EXTRA", "pg_mine"] do
      test "does not create the never-synced #{name}" do
        assert {:error, :table_excluded} = SchemaInspector.create_table(unquote(name), @schema)
        refute table_exists?(unquote(name))
      end
    end

    test "still refuses a name outside the identifier rule first" do
      assert {:error, :invalid_table_name} = SchemaInspector.create_table("bad-name", @schema)
    end

    test "creates a table that may be synced" do
      assert :ok = SchemaInspector.create_table("unsh_created", @schema)
      assert table_exists?("unsh_created")
    end

    test "the import worker leaves no never-synced table behind" do
      job = %Oban.Job{
        args: %{
          "table" => "partner_api_keys",
          "records" => [%{"id" => 1}],
          "strategy" => "skip",
          "schema" => @schema
        }
      }

      capture_log(fn ->
        assert {:error, {:table_creation_failed, :table_excluded}} = ImportWorker.perform(job)
      end)

      refute table_exists?("partner_api_keys")
    end
  end

  # ===========================================
  # DataExporter and the identifier rule
  # ===========================================

  describe "DataExporter and a name outside the identifier rule" do
    setup do
      repo().query!(~s[CREATE TABLE "customer-data" (id bigint PRIMARY KEY, label text)])
      repo().query!(~s[INSERT INTO "customer-data" VALUES (1, 'private')])
      repo().query!("CREATE TABLE unsh_plain (id bigint PRIMARY KEY, label text)")
      repo().query!("INSERT INTO unsh_plain VALUES (1, 'a')")
      :ok
    end

    test "the table is real and the rule refuses its name" do
      assert table_exists?("customer-data")
      refute SchemaInspector.valid_identifier?("customer-data")
    end

    test "get_count/2 refuses it" do
      assert {:error, :invalid_table_name} = DataExporter.get_count("customer-data")
    end

    test "fetch_records/2 refuses it" do
      assert {:error, :invalid_table_name} = DataExporter.fetch_records("customer-data")
    end

    test "fetch_page/2 refuses it" do
      assert {:error, :invalid_table_name} = DataExporter.fetch_page("customer-data")
    end

    test "stream_records/2 refuses it" do
      assert {:error, :invalid_table_name} = DataExporter.stream_records("customer-data")
    end

    test "a schema or an order column outside the rule is refused as well" do
      assert {:error, :invalid_table_name} =
               DataExporter.fetch_records("unsh_plain", schema: "pub-lic")

      assert {:error, :invalid_table_name} = DataExporter.get_count("unsh_plain", schema: ~s[a"b])

      assert {:error, :invalid_column_name} =
               DataExporter.fetch_records("unsh_plain", order_by: ["id; drop"])

      assert {:error, :invalid_column_name} =
               DataExporter.fetch_records("unsh_plain", order_by: "la bel")
    end

    test "a plain table is still read" do
      assert {:ok, [%{"id" => 1, "label" => "a"}]} = DataExporter.fetch_records("unsh_plain")
      assert {:ok, 1} = DataExporter.get_count("unsh_plain")
      assert {:ok, stream} = DataExporter.stream_records("unsh_plain")
      assert Enum.to_list(stream) == [[%{"id" => 1, "label" => "a"}]]
    end

    test "a code session's socket does not read it" do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "ABCD2345", session: %{})
      state = %{state | joined: true}

      frame =
        Jason.encode!([
          nil,
          "1",
          "transfer:ABCD2345",
          "request:records",
          %{"table" => "customer-data", "ref" => "r"}
        ])

      assert {:push, {:text, reply}, _state} =
               SyncWebsock.handle_in({frame, [opcode: :text]}, state)

      assert [_, _, _, "response:error", %{"error" => error}] = Jason.decode!(reply)
      assert error =~ "invalid_table_name"
      refute reply =~ "private"
    end
  end

  # ===========================================
  # The cursor: what is issued is what is accepted
  # ===========================================

  describe "PullCursor with long key values" do
    @cap PullCursor.max_value_bytes()

    defp round_trip(key, row) do
      with {:ok, position} <- PullCursor.next_after(key, row),
           {:ok, accepted} <- PullCursor.from_params(%{"after" => position}),
           {:ok, _where, binds} <- PullCursor.where(key, accepted, 0, &~s("#{&1}")) do
        {:ok, binds}
      end
    end

    @long_keys [
      {"text", String.duplicate("k", 3000)},
      {"character varying", String.duplicate("é", 1500)},
      {"bytea", :binary.copy(<<0xFF>>, 2000)},
      {"numeric", Decimal.new(1, String.to_integer(String.duplicate("9", 4000)), 0)},
      {"numeric", Decimal.new(-1, String.to_integer(String.duplicate("3", 4000)), -4000)}
    ]

    for {{type, value}, index} <- Enum.with_index(@long_keys) do
      test "a long #{type} key continues (case #{index})" do
        key = [{"k", unquote(type)}]
        assert {:ok, [text]} = round_trip(key, %{"k" => unquote(Macro.escape(value))})
        assert byte_size(text) > 1024
        assert byte_size(text) <= @cap
      end
    end

    @too_long [
      {"text", String.duplicate("k", 8193)},
      {"character", String.duplicate("k", 20_000)},
      {"bytea", :binary.copy(<<1>>, 4096)},
      {"numeric", Decimal.new(1, String.to_integer(String.duplicate("9", 9000)), 0)}
    ]

    for {type, value} <- @too_long do
      test "a #{type} key value past the cap has no cursor, and says why" do
        key = [{"k", unquote(type)}]

        assert {:too_long, unquote(type)} =
                 PullCursor.next_after(key, %{"k" => unquote(Macro.escape(value))})
      end
    end

    test "the cap is the same on the way in" do
      assert {:ok, _} =
               PullCursor.from_params(%{"after" => %{"k" => String.duplicate("k", @cap)}})

      assert {:error, :invalid_cursor} =
               PullCursor.from_params(%{"after" => %{"k" => String.duplicate("k", @cap + 1)}})
    end

    test "a long text key pages through its table" do
      repo().query!("CREATE TABLE unsh_long_keys (k text PRIMARY KEY)")

      keys = for n <- 1..3, do: String.duplicate("k", 2000) <> Integer.to_string(n)
      for k <- keys, do: repo().query!("INSERT INTO unsh_long_keys VALUES ($1)", [k])

      assert {:ok, %{records: [%{"k" => first}], next_after: %{} = position}} =
               DataExporter.fetch_page("unsh_long_keys", limit: 1)

      {:ok, position} = PullCursor.from_params(%{"after" => position})

      assert {:ok, %{records: [%{"k" => second}, %{"k" => third}]}} =
               DataExporter.fetch_page("unsh_long_keys", limit: 5, after: position)

      assert [first, second, third] == keys
    end
  end

  # ===========================================
  # The bytea wrapper, by column type
  # ===========================================

  describe "a JSON object shaped like the bytea wrapper" do
    @wrapper %{"__phoenix_kit_binary__" => "YQ=="}

    for type <- ["json", "jsonb", "text", "character varying", "integer"] do
      test "stays an object in a #{type} column" do
        assert Prepare.value(@wrapper, "c", %{}, %{"c" => unquote(type)}) == @wrapper
        assert Prepare.key_value(@wrapper, unquote(type)) == @wrapper
      end
    end

    for type <- ["bytea", "uuid"] do
      test "is the bytes it wraps in a #{type} column" do
        assert Prepare.value(@wrapper, "c", %{}, %{"c" => unquote(type)}) == "a"
        assert Prepare.key_value(@wrapper, unquote(type)) == "a"
      end
    end

    test "bytea elements of an array are still unwrapped, json ones are not" do
      assert Prepare.value([@wrapper], "c", %{}, %{"c" => {:array, "bytea"}}) == ["a"]
      assert Prepare.value([@wrapper], "c", %{}, %{"c" => {:array, "jsonb"}}) == [@wrapper]
    end

    test "is stored as the object by a pull" do
      repo().query!("CREATE TABLE unsh_json (id bigint PRIMARY KEY, doc jsonb, raw bytea)")

      StubRemote.reset()
      on_exit(&StubRemote.reset/0)

      StubRemote.put_data("unsh_json", [%{"id" => 1, "doc" => @wrapper, "raw" => @wrapper}])

      {:ok, connection, _token} =
        Connections.create_connection(%{
          "name" => "Stub sender #{System.unique_integer([:positive])}",
          "direction" => "receiver",
          "site_url" => StubRemote.url(),
          "status" => "active"
        })

      capture_log(fn ->
        assert {:ok, _} = ConnectionNotifier.pull_table_data(connection, "unsh_json")
      end)

      assert repo().query!("SELECT doc, raw FROM unsh_json").rows == [[@wrapper, "a"]]
    end

    test "is stored as the object by the socket import" do
      repo().query!("CREATE TABLE unsh_json_ws (id bigint PRIMARY KEY, doc jsonb, raw bytea)")

      assert {:ok, %{created: 1}} =
               DataImporter.import_records(
                 "unsh_json_ws",
                 [%{"id" => 1, "doc" => @wrapper, "raw" => @wrapper}],
                 :skip
               )

      assert repo().query!("SELECT doc, raw FROM unsh_json_ws").rows == [[@wrapper, "a"]]
    end
  end

  # ===========================================
  # Malformed answers
  # ===========================================

  describe "a sender's malformed successful answer" do
    setup do
      StubRemote.reset()
      on_exit(&StubRemote.reset/0)

      {:ok, connection, _token} =
        Connections.create_connection(%{
          "name" => "Stub sender #{System.unique_integer([:positive])}",
          "direction" => "receiver",
          "site_url" => StubRemote.url(),
          "status" => "active"
        })

      {:ok, connection: connection}
    end

    @bad_tables [
      42,
      "tables",
      %{"name" => "a"},
      [42],
      [%{"name" => "a"}, "b"],
      [%{"name" => 7}],
      [%{"row_count" => 1}],
      [nil]
    ]

    for {tables, index} <- Enum.with_index(@bad_tables) do
      test "tables: #{inspect(tables)} is an invalid response (case #{index})", %{
        connection: connection
      } do
        StubRemote.put_tables(unquote(Macro.escape(tables)))
        assert {:error, :invalid_response} = ConnectionNotifier.fetch_sender_tables(connection)
      end
    end

    test "a table entry's fields of the wrong type read as absent", %{connection: connection} do
      StubRemote.put_tables([
        %{
          "name" => "a",
          "row_count" => "many",
          "size_bytes" => nil,
          "checksum" => 5,
          "depends_on" => ["b", 7, %{}]
        }
      ])

      assert {:ok, [%{name: "a", row_count: 0, size_bytes: 0, checksum: nil, depends_on: ["b"]}]} =
               ConnectionNotifier.fetch_sender_tables(connection)
    end

    test "the table list has room that the other answers do not, and a bound", %{
      connection: connection
    } do
      # Past 1 MiB, which a few thousand tables reach.
      StubRemote.put_tables(
        for n <- 1..6000,
            do: %{"name" => "table_#{n}", "checksum" => String.duplicate("c", 200)}
      )

      assert {:ok, tables} = ConnectionNotifier.fetch_sender_tables(connection)
      assert length(tables) == 6000

      # Past 16 MiB.
      StubRemote.put_tables(
        for n <- 1..900,
            do: %{"name" => "table_#{n}", "checksum" => String.duplicate("c", 20_000)}
      )

      assert {:error, :response_too_large} = ConnectionNotifier.fetch_sender_tables(connection)
    end
  end

  describe "ConnectionNotifier.fetch_table_records/3 and a malformed answer" do
    # The stub does not serve table-records; a plug of this test's own does.
    defmodule Records do
      @moduledoc false
      import Plug.Conn

      def init(opts), do: opts

      def call(conn, _opts) do
        body = Application.get_env(:phoenix_kit_sync, :unsh_records_body)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      end
    end

    setup do
      {:ok, server} = Bandit.start_link(plug: Records, port: 0, ip: :loopback)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      on_exit(fn -> Application.delete_env(:phoenix_kit_sync, :unsh_records_body) end)

      {:ok, connection: %{site_url: "http://localhost:#{port}", auth_token_hash: "hash"}}
    end

    defp answer(body),
      do: Application.put_env(:phoenix_kit_sync, :unsh_records_body, Jason.encode!(body))

    for records <- [42, "rows", %{"a" => 1}, [1], [%{"id" => 1}, 42], [nil]] do
      test "records: #{inspect(records)} is an invalid response", %{connection: connection} do
        answer(%{"success" => true, "records" => unquote(Macro.escape(records))})

        assert {:error, :invalid_response} =
                 ConnectionNotifier.fetch_table_records(connection, "t")
      end
    end

    test "a list of objects is taken", %{connection: connection} do
      answer(%{"success" => true, "records" => [%{"id" => 1}]})
      assert {:ok, [%{"id" => 1}]} = ConnectionNotifier.fetch_table_records(connection, "t")
    end
  end

  describe "a page of records with something that is not a record in it" do
    setup do
      {:ok,
       state: %WebSocketClient{
         url: "ws://example.com",
         code: "ABCD2345",
         caller: self(),
         receiver_info: %{},
         ref_counter: 0,
         pending_refs: %{"1" => {:records, "rows"}},
         joined: true,
         heartbeat_ref: nil
       }}
    end

    defp records_frame(records) do
      Jason.encode!([
        nil,
        nil,
        "transfer:ABCD2345",
        "response:records",
        %{"records" => records, "ref" => "1", "offset" => 0}
      ])
    end

    @bad_pages [
      [%{"id" => 1}, 42, %{"id" => 3}],
      [42, "x", nil],
      [[%{"id" => 1}]],
      "rows",
      42,
      %{"id" => 1}
    ]

    for {page, index} <- Enum.with_index(@bad_pages) do
      test "#{inspect(page)} fails the table's request (case #{index})", %{state: state} do
        log =
          capture_log(fn ->
            assert {:ok, state} =
                     WebSocketClient.handle_frame(
                       {:text, records_frame(unquote(Macro.escape(page)))},
                       state
                     )

            assert state.pending_refs == %{}
          end)

        assert_received {:sync_client, {:request_error, {:records, "rows"}, :invalid_response}}
        refute_received {:sync_client, {:records, _table, _result}}
        assert log =~ "Malformed page"
      end
    end

    test "a page of records is taken whole", %{state: state} do
      page = [%{"id" => 1}, %{"id" => 2}]

      assert {:ok, _state} = WebSocketClient.handle_frame({:text, records_frame(page)}, state)
      assert_received {:sync_client, {:records, "rows", %{records: ^page}}}
    end

    test "an empty page is the end of the table, not an error", %{state: state} do
      assert {:ok, _state} = WebSocketClient.handle_frame({:text, records_frame([])}, state)
      assert_received {:sync_client, {:records, "rows", %{records: []}}}
    end
  end

  describe "a request on the serving socket whose payload is not an object" do
    setup do
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "ABCD2345", session: %{})
      {:ok, state: %{state | joined: true}}
    end

    @events ~w(request:records request:tables request:schema request:count request:capabilities)

    for event <- @events, payload <- [42, "x", nil, [1, 2], true, ["table"]] do
      test "#{event} with #{inspect(payload)} is ignored", %{state: state} do
        frame =
          Jason.encode!([
            nil,
            "1",
            "transfer:ABCD2345",
            unquote(event),
            unquote(Macro.escape(payload))
          ])

        capture_log(fn ->
          assert {:ok, ^state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
        end)
      end
    end
  end
end
