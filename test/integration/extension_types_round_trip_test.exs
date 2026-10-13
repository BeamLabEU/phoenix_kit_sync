defmodule PhoenixKitSync.Integration.ExtensionTypesRoundTripTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.ExtensionTypes
  alias PhoenixKitSync.Test.StubRemote

  # Column types Postgrex returns as a struct of its own. The ones sync
  # carries come back as the value they were, on both protocols; the ones
  # it does not fail their record with the type named, and are never stored
  # as text that only looks like the value. Each case is a real row read by
  # the real exporter, deleted, and written back by the real importer.

  @table "ext_rows"

  # {column, type, SQL literals}
  @carried [
    {"c_interval", "interval",
     [
       "'1 year 2 mons 3 days 04:05:06.000007'",
       "'-1 mons +2 days -00:00:00.5'",
       "'30 days'",
       "'1 mon'",
       "'00:00:00'",
       "'-178000000 years'",
       "'2562047788:00:54.775807'",
       "'0.000001 seconds'"
     ]},
    {"c_inet", "inet",
     [
       "'10.1.2.3'",
       "'192.168.1.5/24'",
       "'0.0.0.0/0'",
       "'::1'",
       "'2001:db8::1/64'",
       "'::ffff:10.0.0.1'"
     ]},
    {"c_cidr", "cidr", ["'10.0.0.0/8'", "'192.168.1.5/32'", "'2001:db8::/32'", "'::/0'"]},
    {"c_macaddr", "macaddr",
     ["'08:00:2b:01:02:03'", "'00:00:00:00:00:00'", "'ff:ff:ff:ff:ff:ff'"]}
  ]

  # {column, type, SQL literal, the name the record's error carries}
  @refused [
    {"r_int4range", "int4range", "'[1,5)'", "Postgrex.Range"},
    {"r_tsrange", "tsrange", "'[2026-01-01 00:00, 2026-01-02 00:00)'", "Postgrex.Range"},
    {"r_point", "point", "'(1,2)'", "Postgrex.Point"},
    {"r_box", "box", "'((0,0),(1,1))'", "Postgrex.Box"},
    {"r_circle", "circle", "'<(0,0),1>'", "Postgrex.Circle"},
    {"r_tsvector", "tsvector", "'a fat cat'", "Postgrex.Lexeme"}
  ]

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    columns =
      Enum.map_join(@carried ++ @refused, ", ", fn spec -> "#{elem(spec, 0)} #{elem(spec, 1)}" end)

    repo().query!(
      "CREATE TABLE #{@table} (id bigint PRIMARY KEY, label text, #{columns}, j jsonb)"
    )

    {:ok, _sender, token} =
      Connections.create_connection(%{
        "name" => "Types sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://types-#{System.unique_integer([:positive])}.example.com",
        "status" => "active"
      })

    {:ok, receiver, _token} =
      Connections.create_connection(%{
        "name" => "Types receiver #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url(),
        "status" => "active"
      })

    {:ok, receiver: receiver, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp stored(column) do
    case repo().query!(~s[SELECT "#{column}"::text FROM #{@table} WHERE id = 1]) do
      %{rows: [[text]]} -> {:stored, text}
      %{rows: []} -> :no_row
    end
  end

  defp insert!(column, sql_value),
    do:
      repo().query!(
        ~s[INSERT INTO #{@table} (id, label, "#{column}") VALUES (1, 'row', #{sql_value})]
      )

  # What the sender puts on the wire, having gone through JSON as it does
  # on either protocol.
  defp export(:http, %{hash: hash}) do
    build_conn()
    |> post("/sync/api/pull-data", %{"auth_token_hash" => hash, "table_name" => @table})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp export(:websocket, _context) do
    {:ok, records} = DataExporter.fetch_records(@table)
    records |> Jason.encode!() |> Jason.decode!()
  end

  # `{imported, errors, message}`: the message of the failed record, where
  # the path gives one back.
  defp import_back(:http, %{receiver: receiver}, records) do
    StubRemote.put_data(@table, records)

    {:ok, result} =
      ConnectionNotifier.pull_table_data(receiver, @table, conflict_strategy: "overwrite")

    {result.imported, result.errors, nil}
  end

  defp import_back(:websocket, _context, records) do
    {:ok, result} = DataImporter.import_records(@table, records, :overwrite)

    message =
      case result.errors do
        [{_record, message} | _] -> message
        [] -> nil
      end

    {result.created + result.updated, length(result.errors), message}
  end

  for path <- [:http, :websocket], {column, type, literals} <- @carried do
    for {literal, index} <- Enum.with_index(literals) do
      test "#{path}: #{type} #{literal} comes back as it was (case #{index})", context do
        insert!(unquote(column), unquote(literal) <> "::" <> unquote(type))
        before = stored(unquote(column))
        assert {:stored, _text} = before

        [record] = export(unquote(path), context)
        assert is_binary(record[unquote(column)])

        repo().query!("DELETE FROM #{@table}")

        assert {1, 0, nil} = import_back(unquote(path), context, [record])
        assert stored(unquote(column)) == before
      end
    end

    test "#{path}: a NULL #{type} stays NULL", context do
      insert!(unquote(column), "NULL")
      [record] = export(unquote(path), context)
      repo().query!("DELETE FROM #{@table}")

      assert {1, 0, nil} = import_back(unquote(path), context, [record])
      assert stored(unquote(column)) == {:stored, nil}
    end

    test "#{path}: text that is no #{type} fails its record, not the import", context do
      records = [
        %{"id" => 1, "label" => "bad", unquote(column) => "%Postgrex.Interval{months: 1}"},
        %{"id" => 2, "label" => "good"}
      ]

      assert {1, 1, _message} = import_back(unquote(path), context, records)
      assert %{rows: [[2]]} = repo().query!("SELECT id FROM #{@table}")
    end
  end

  for path <- [:http, :websocket], {column, type, literal, name} <- @refused do
    test "#{path}: a #{type} value is marked by the sender and fails its record on import",
         context do
      insert!(unquote(column), unquote(literal) <> "::" <> unquote(type))

      [record] = export(unquote(path), context)
      assert record[unquote(column)] == %{"__phoenix_kit_unsupported__" => unquote(name)}

      repo().query!("DELETE FROM #{@table}")
      other = %{"id" => 2, "label" => "plain"}

      assert {1, 1, message} = import_back(unquote(path), context, [record, other])
      assert %{rows: [[2]]} = repo().query!("SELECT id FROM #{@table}")

      if unquote(path) == :websocket do
        assert message =~ unquote(name)
        assert message =~ "sync does not carry"
      end
    end
  end

  for path <- [:http, :websocket] do
    test "#{path}: a jsonb object shaped like the marker is an object", context do
      insert!("j", ~s('{"__phoenix_kit_unsupported__": "Postgrex.Range"}'::jsonb))
      before = stored("j")

      [record] = export(unquote(path), context)
      repo().query!("DELETE FROM #{@table}")

      assert {1, 0, nil} = import_back(unquote(path), context, [record])
      assert stored("j") == before
    end
  end

  describe "ExtensionTypes.parse/2" do
    @not_values [
      {"interval", "1 mons 2 days"},
      {"interval", "1 mons 2 days 3 microseconds; DROP TABLE x"},
      {"interval", "P1Y"},
      {"interval", "1.5 mons 0 days 0 microseconds"},
      {"interval", ""},
      {"inet", "10.0.0"},
      {"inet", "10.0.0.1/33"},
      {"inet", "::1/129"},
      {"inet", "10.0.0.1/-1"},
      {"inet", "example.com"},
      {"inet", "10.0.0.1/8/8"},
      {"cidr", "2130706433"},
      {"macaddr", "08:00:2b:01:02"},
      {"macaddr", "08:00:2b:01:02:zz"},
      {"macaddr", "8:0:2b:1:2:3"},
      {"text", "anything"}
    ]

    for {{type, text}, index} <- Enum.with_index(@not_values) do
      test "#{inspect(text)} is no #{type} (case #{index})" do
        assert ExtensionTypes.parse(unquote(type), unquote(text)) == :error
      end
    end
  end
end
