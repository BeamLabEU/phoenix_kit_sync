defmodule PhoenixKitSync.Integration.HttpArrayValuesTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote

  # Array columns over HTTP, both ends real: the row is read through the
  # `pull-data` action, deleted, and written back by a pull that is served
  # exactly what the action answered. Every column type is crossed with
  # every shape an array takes, and the stored value is compared as text.

  @table "harr_rows"

  # A uuid whose 16 bytes happen to be UTF-8 ("ABCD…") and one whose bytes
  # are not: neither may decide how an element travels.
  @text_uuid "41424344-4546-4748-494a-4b4c4d4e4f50"
  @raw_uuid "ffa0b2c3-7c3e-4d4f-8a1b-2c3d4e5f6071"

  # {column, element type DDL, two element literals}
  @types [
    {"a_uuid", "uuid", ["'#{@text_uuid}'", "'#{@raw_uuid}'"]},
    {"a_text", "text", ["'2026-01-01'", "'a \"quoted\", one'"]},
    {"a_varchar", "varchar(20)", ["'12:30:00'", "'3.14'"]},
    {"a_int", "integer", ["1", "-2147483648"]},
    {"a_bigint", "bigint", ["9223372036854775807", "-5"]},
    {"a_numeric", "numeric", ["1.50", "-12345678901234567890.123456789"]},
    {"a_float", "double precision", ["1.5", "-2.25e300"]},
    {"a_bool", "boolean", ["true", "false"]},
    {"a_tstz", "timestamptz", ["'2026-01-01 12:30:00.123456+00'", "'1999-12-31 23:59:59+00'"]},
    {"a_ts", "timestamp", ["'2026-01-01 12:30:00.123456'", "'1999-12-31 23:59:59'"]},
    {"a_date", "date", ["'2026-01-01'", "'1999-12-31'"]},
    {"a_time", "time", ["'12:30:00.123456'", "'00:00:00'"]},
    {"a_bytea", "bytea", ["'\\xff00'", "'\\x414243'"]},
    {"a_interval", "interval",
     ["'1 year 2 mons 3 days 04:05:06.000007'", "'-45 days -00:00:00.5'"]},
    {"a_inet", "inet", ["'10.1.2.3'", "'2001:db8::1/64'"]},
    {"a_cidr", "cidr", ["'10.0.0.0/8'", "'2001:db8::/32'"]},
    {"a_macaddr", "macaddr", ["'08:00:2b:01:02:03'", "'ff:ff:ff:ff:ff:ff'"]}
  ]

  # {shape, the SQL value with the type and its two literals left open}
  @shapes [
    {"values", "ARRAY[<a>, <b>]::<t>[]"},
    {"one value", "ARRAY[<a>]::<t>[]"},
    {"a NULL element", "ARRAY[<a>, NULL, <b>]::<t>[]"},
    {"only NULL elements", "ARRAY[NULL, NULL]::<t>[]"},
    {"empty", "'{}'::<t>[]"},
    {"NULL", "NULL::<t>[]"},
    {"two dimensions", "ARRAY[[<a>, <b>], [<b>, <a>]]::<t>[]"},
    {"two dimensions with a NULL", "ARRAY[[<a>, NULL], [NULL, <b>]]::<t>[]"}
  ]

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    columns = Enum.map_join(@types, ", ", fn {column, type, _values} -> "#{column} #{type}[]" end)

    repo().query!(
      "CREATE TABLE #{@table} (id bigint PRIMARY KEY, #{columns}, a_jsonb jsonb[], j jsonb)"
    )

    {:ok, _sender, token} =
      Connections.create_connection(%{
        "name" => "Array sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://arrays-#{System.unique_integer([:positive])}.example.com",
        "status" => "active"
      })

    {:ok, receiver, _token} =
      Connections.create_connection(%{
        "name" => "Array receiver #{System.unique_integer([:positive])}",
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

  # Reads the row through the sender's action, removes it, and pulls it
  # back from a remote that answers what the action answered.
  defp round_trip(%{receiver: receiver, hash: hash}, column, sql_value) do
    repo().query!(~s[INSERT INTO #{@table} (id, "#{column}") VALUES (1, #{sql_value})])
    before = stored(column)

    answer =
      build_conn()
      |> post("/sync/api/pull-data", %{"auth_token_hash" => hash, "table_name" => @table})
      |> json_response(200)

    assert [%{"id" => 1}] = answer["data"]

    repo().query!("DELETE FROM #{@table}")
    StubRemote.put_data(@table, answer["data"])

    assert {:ok, %{imported: 1, errors: 0}} =
             ConnectionNotifier.pull_table_data(receiver, @table, conflict_strategy: "overwrite")

    {before, stored(column)}
  end

  for {column, type, [a, b]} <- @types, {shape, template} <- @shapes do
    sql_value =
      template
      |> String.replace("<a>", a)
      |> String.replace("<b>", b)
      |> String.replace("<t>", type)

    test "#{type}[] #{shape} comes back as it was", context do
      {before, pulled} = round_trip(context, unquote(column), unquote(sql_value))

      assert {:stored, _text} = before
      assert pulled == before
    end
  end

  # A JSON null element is left out: Postgrex reads it as nil, the same as
  # a NULL element, so it comes back as NULL on any path.
  @json_arrays [
    {"objects and scalars", ~s(ARRAY['{"k": "2026-01-01"}', '"s"', '42', 'true']::jsonb[])},
    {"a NULL element", ~s(ARRAY['{"k": 1}', NULL]::jsonb[])},
    {"array elements", ~s(ARRAY['[1, 2]', '[3, [4, 5]]']::jsonb[])},
    {"an element shaped like the bytes wrapper",
     ~s(ARRAY['{"__phoenix_kit_binary__": "AAE="}']::jsonb[])},
    {"empty", "'{}'::jsonb[]"},
    {"NULL", "NULL::jsonb[]"}
  ]

  for {shape, sql_value} <- @json_arrays do
    test "jsonb[] #{shape} comes back as it was", context do
      {before, pulled} = round_trip(context, "a_jsonb", unquote(sql_value))

      assert {:stored, _text} = before
      assert pulled == before
    end
  end

  @json_values [
    {"a list", ~s('[1, [2, 3], "2026-01-01", null]'::jsonb)},
    {"an object holding lists", ~s('{"k": [1, 2], "day": "2026-01-01"}'::jsonb)},
    {"an empty list", "'[]'::jsonb"},
    {"a list of uuid text", ~s('["#{@text_uuid}"]'::jsonb)}
  ]

  for {shape, sql_value} <- @json_values do
    test "a jsonb column holding #{shape} is not read as an array column", context do
      {before, pulled} = round_trip(context, "j", unquote(sql_value))

      assert {:stored, _text} = before
      assert pulled == before
    end
  end

  # `table-records` (the preview a receiver shows before a pull) reads the
  # same rows, so it serializes arrays the same way.
  test "table-records answers array columns element by element", %{hash: hash} do
    repo().query!("""
    INSERT INTO #{@table} (id, a_uuid, a_bytea, a_numeric, a_date)
    VALUES (1, ARRAY['#{@raw_uuid}', NULL, '#{@text_uuid}']::uuid[], ARRAY['\\xff00']::bytea[],
            ARRAY[1.50]::numeric[], ARRAY[['2026-01-01'], ['1999-12-31']]::date[])
    """)

    answer =
      build_conn()
      |> post("/sync/api/table-records", %{"auth_token_hash" => hash, "table_name" => @table})
      |> json_response(200)

    assert [record] = answer["records"]
    assert record["a_uuid"] == [@raw_uuid, nil, @text_uuid]
    assert record["a_bytea"] == [%{"__phoenix_kit_binary__" => Base.encode64(<<255, 0>>)}]
    assert record["a_numeric"] == ["1.50"]
    assert record["a_date"] == [["2026-01-01"], ["1999-12-31"]]
  end

  test "pull-data writes a uuid element as its text whatever its bytes are", %{hash: hash} do
    repo().query!(
      "INSERT INTO #{@table} (id, a_uuid) VALUES (1, ARRAY['#{@text_uuid}', '#{@raw_uuid}']::uuid[])"
    )

    answer =
      build_conn()
      |> post("/sync/api/pull-data", %{"auth_token_hash" => hash, "table_name" => @table})
      |> json_response(200)

    assert [%{"a_uuid" => [@text_uuid, @raw_uuid]}] = answer["data"]
  end

  # The elements are the sender's: one that cannot be read fails its own
  # record and leaves the others, and the pull, standing.
  test "an array with an unreadable element fails that record only", %{receiver: receiver} do
    StubRemote.put_data(@table, [
      %{"id" => 1, "a_date" => [%{"__type__" => "date", "value" => 5}]},
      %{"id" => 2, "a_uuid" => ["not-a-uuid"]},
      %{"id" => 3, "a_int" => "not a list"},
      %{"id" => 4, "a_numeric" => ["1.5", %{"nested" => "map"}]},
      %{"id" => 5, "a_int" => [1, 2], "a_date" => ["2026-01-01"]}
    ])

    assert {:ok, %{imported: 1, errors: 4}} =
             ConnectionNotifier.pull_table_data(receiver, @table, conflict_strategy: "overwrite")

    assert %{rows: [[5, [1, 2], [~D[2026-01-01]]]]} =
             repo().query!("SELECT id, a_int, a_date FROM #{@table}")
  end
end
