defmodule PhoenixKitSync.Integration.PullCursorSenderTest do
  use PhoenixKitSync.ConnCase, async: false

  import Ecto.Query

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Transfer

  # pull-data stops at max_records_per_request. A receiver that pages sends
  # back "next_after" (and "cursor") for the rest, and gets the rows
  # strictly after that key, in key order, whatever the key is made of.

  @limit 3

  # {table, DDL, INSERT of rows in an order that is not the key order,
  #  query returning every row's key as text in key order}
  @tables [
    {"pc_int", "(id bigint PRIMARY KEY, label text)",
     "SELECT g, 'r' FROM unnest(ARRAY[8,3,6,1,5,2,7,4,10,9]) g", "id::text"},
    {"pc_uuid", "(uuid uuid PRIMARY KEY, label text)",
     "SELECT md5(g::text)::uuid, 'r' FROM generate_series(1, 10) g", "uuid::text"},
    {"pc_text", "(code text PRIMARY KEY, label text)",
     "SELECT c, 'r' FROM unnest(ARRAY['b','a','B','ä','a b','a''b','10','9','Z','é', 'a\\b']) c",
     "code"},
    {"pc_varchar", "(code varchar(20) PRIMARY KEY, label text)",
     "SELECT 'k' || g, 'r' FROM generate_series(1, 10) g", "code"},
    {"pc_pairs", "(a int, b int, label text, PRIMARY KEY (a, b))",
     "SELECT a, b, 'r' FROM generate_series(3, 1, -1) a, generate_series(4, 1, -1) b",
     "a::text || '/' || b::text"},
    {"pc_mixed", "(name text, ref uuid, label text, PRIMARY KEY (name, ref))",
     "SELECT n, md5(g::text)::uuid, 'r' FROM unnest(ARRAY['x','y']) n, generate_series(1, 5) g",
     "name || '/' || ref::text"},
    {"pc_ts", "(at timestamp PRIMARY KEY, label text)",
     "SELECT timestamp '2026-01-01 00:00:00.123456' + (g || ' minutes')::interval, 'r' FROM generate_series(10, 1, -1) g",
     "at::text"},
    {"pc_tstz", "(at timestamptz PRIMARY KEY, label text)",
     "SELECT timestamptz '2026-01-01 00:00:00.5+00' + (g || ' hours')::interval, 'r' FROM generate_series(10, 1, -1) g",
     "at::text"},
    {"pc_date", "(day date PRIMARY KEY, label text)",
     "SELECT date '2026-01-01' + g, 'r' FROM generate_series(10, 1, -1) g", "day::text"},
    {"pc_numeric", "(amount numeric PRIMARY KEY, label text)",
     "SELECT g / 4.0, 'r' FROM generate_series(10, 1, -1) g", "amount::text"}
  ]

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Paging sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://paging-#{System.unique_integer([:positive])}.example.com",
        "status" => "active",
        "max_records_per_request" => @limit
      })

    {:ok,
     connection: connection, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp create!({table, ddl, insert, _key}) do
    repo().query!("CREATE TABLE #{table} #{ddl}")
    repo().query!("INSERT INTO #{table} #{insert}")
  end

  defp request(hash, table, extra) do
    post(
      build_conn(),
      "/sync/api/pull-data",
      Map.merge(%{"auth_token_hash" => hash, "table_name" => table}, extra)
    )
  end

  defp pull(hash, table, extra \\ %{}), do: hash |> request(table, extra) |> json_response(200)

  # Follows the cursor to the end, as a receiver does; returns every page.
  defp walk(hash, table, extra \\ %{}, pages \\ []) do
    body = pull(hash, table, extra)
    pages = pages ++ [body]

    if body["has_more"] do
      assert length(pages) < 50, "the cursor of #{table} does not advance"
      next = %{"after" => body["next_after"], "cursor" => body["cursor"], "paged" => true}
      walk(hash, table, Map.merge(extra, next), pages)
    else
      pages
    end
  end

  defp downloads(connection), do: Connections.get_connection!(connection.uuid).downloads_used

  for {table, _ddl, _insert, key} = spec <- @tables do
    test "#{table}: the pages are the whole table, each row once, in key order", %{hash: hash} do
      create!(unquote(Macro.escape(spec)))
      table = unquote(table)

      %{rows: [[total]]} = repo().query!("SELECT count(*) FROM #{table}")
      pages = walk(hash, table)

      assert length(pages) == ceil(total / @limit)
      assert Enum.all?(Enum.drop(pages, -1), &(length(&1["data"]) == @limit))

      # Each page's own keys, read back from the database in key order: the
      # pages laid end to end are the table laid out by its key.
      %{rows: expected} =
        repo().query!("SELECT #{unquote(key)} FROM #{table} ORDER BY #{order_by(table)}")

      assert pages |> Enum.flat_map(& &1["data"]) |> length() == total

      seen =
        Enum.flat_map(pages, fn page ->
          keys_of(table, page["data"])
        end)

      assert seen == List.flatten(expected)
    end
  end

  defp order_by("pc_pairs"), do: "a, b"
  defp order_by("pc_mixed"), do: "name, ref"

  defp order_by(table) do
    %{rows: [[column]]} =
      repo().query!(
        "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid " <>
          "AND a.attnum = ANY(i.indkey) WHERE i.indisprimary AND i.indrelid = $1::text::regclass",
        [table]
      )

    # Qualified: a bare name would sort by the SELECT's text column of the
    # same name.
    ~s(#{table}."#{column}")
  end

  # The keys of the records in a page, as the text the database gives for
  # them: asked of the database by the page's position, not parsed from JSON.
  defp keys_of(_table, []), do: []

  defp keys_of(table, records) do
    {_table, _ddl, _insert, key} = Enum.find(@tables, &(elem(&1, 0) == table))
    seen = Process.get({:offset, table}, 0)
    Process.put({:offset, table}, seen + length(records))

    %{rows: rows} =
      repo().query!(
        "SELECT #{key} FROM #{table} ORDER BY #{order_by(table)} LIMIT $1 OFFSET $2",
        [length(records), seen]
      )

    page_keys = List.flatten(rows)
    assert length(page_keys) == length(records)
    assert_same_rows(table, records, page_keys)
    page_keys
  end

  # The records of the page are the rows at that position: checked on a
  # column whose JSON form is unambiguous where the table has one.
  defp assert_same_rows("pc_int", records, keys),
    do: assert(Enum.map(records, &to_string(&1["id"])) == keys)

  defp assert_same_rows("pc_text", records, keys),
    do: assert(Enum.map(records, & &1["code"]) == keys)

  defp assert_same_rows("pc_varchar", records, keys),
    do: assert(Enum.map(records, & &1["code"]) == keys)

  defp assert_same_rows("pc_pairs", records, keys),
    do: assert(Enum.map(records, &"#{&1["a"]}/#{&1["b"]}") == keys)

  defp assert_same_rows("pc_date", records, keys),
    do: assert(Enum.map(records, & &1["day"]) == keys)

  defp assert_same_rows(_table, _records, _keys), do: :ok

  # Key types whose text reads back as exactly the value, the values that
  # could go wrong included: a float that has no short decimal, NaN and the
  # infinities, a real widened to a double on its way out, padded
  # characters, bytes that are no text. Each row carries its rank in key
  # order, so the pages laid end to end must count 1..n: a skipped row
  # leaves a gap and a repeated one a double.
  @exact_keys [
    {"pc_real", "real",
     ~w(0.1 1e-45 3.4028235e38 -2.5 NaN Infinity -Infinity 0.3333333 16777216 1e10 7)},
    {"pc_double", "double precision",
     ~w(0.1 5e-324 1.7976931348623157e308 -2.5 NaN Infinity -Infinity 0.3333333333333333 1e22 1e23 3)},
    {"pc_char", "character(5)", ["a", "b", "ab", "a b", "B", "é", "10", "9", "", "zz"]},
    {"pc_time", "time",
     ~w(00:00:00 12:30:00.123456 23:59:59.999999 12:30:00 06:00:00.5 12:30:00.123457 01:02:03 18:00 00:00:00.000001 09:09:09)},
    {"pc_bytea", "bytea", ~w(\\x00 \\xff \\x4142 \\x \\x00ff \\xff00 \\x41 \\x4141 \\x7f \\x80)},
    {"pc_bool", "boolean", ~w(true false)}
  ]

  defp create_ranked!(table, type, values) do
    repo().query!("CREATE TABLE #{table} (k #{type} PRIMARY KEY, n int)")

    for value <- values do
      repo().query!("INSERT INTO #{table} (k) VALUES ($1::text::#{type})", [value])
    end

    repo().query!(
      "UPDATE #{table} t SET n = r.n FROM " <>
        "(SELECT ctid, row_number() OVER (ORDER BY k) AS n FROM #{table}) r WHERE t.ctid = r.ctid"
    )
  end

  for {table, type, values} <- @exact_keys do
    test "#{type} key: the pages are every row once, in key order", %{hash: hash} do
      create_ranked!(unquote(table), unquote(type), unquote(values))

      pages = walk(hash, unquote(table))
      ranks = pages |> Enum.flat_map(& &1["data"]) |> Enum.map(& &1["n"])

      assert ranks == Enum.to_list(1..unquote(length(values)))
      assert length(pages) == ceil(unquote(length(values)) / @limit)
      refute Enum.any?(pages, &Map.has_key?(&1, "unsupported_key_type"))
    end
  end

  test "a boolean in a composite key continues inside and across its values", %{hash: hash} do
    repo().query!("CREATE TABLE pc_flags (a boolean, b int, n int, PRIMARY KEY (a, b))")

    repo().query!(
      "INSERT INTO pc_flags (a, b) SELECT f, g FROM unnest(ARRAY[true, false]) f, generate_series(4, 1, -1) g"
    )

    repo().query!(
      "UPDATE pc_flags t SET n = r.n FROM " <>
        "(SELECT ctid, row_number() OVER (ORDER BY a, b) AS n FROM pc_flags) r WHERE t.ctid = r.ctid"
    )

    ranks = hash |> walk("pc_flags") |> Enum.flat_map(& &1["data"]) |> Enum.map(& &1["n"])

    assert ranks == Enum.to_list(1..8)
  end

  @bad_typed_cursors [
    {"real", "abc"},
    {"real", "1.5; DROP TABLE pc_bad"},
    {"double precision", ""},
    {"double precision", "nan()"},
    {"double precision", "1.0e-400"},
    {"double precision", "1e999"},
    {"real", "1"},
    {"boolean", "yes"},
    {"boolean", "1"},
    {"time", "25:00:00"},
    {"time", "noon"},
    {"bytea", "4142"},
    {"bytea", "\\xzz"},
    {"bytea", "\\x4"}
  ]

  for {{type, bad}, index} <- Enum.with_index(@bad_typed_cursors) do
    test "#{type} key: after=#{inspect(bad)} (case #{index}) is a 400, not a failed query", %{
      hash: hash
    } do
      repo().query!("CREATE TABLE pc_bad (k #{unquote(type)} PRIMARY KEY)")

      assert %{"success" => false, "error_code" => "invalid_cursor"} =
               hash
               |> request("pc_bad", %{"after" => %{"k" => unquote(bad)}})
               |> json_response(400)
    end
  end

  describe "compatibility" do
    setup do
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_int")))
      :ok
    end

    test "a receiver that sends no cursor gets what it always got", %{hash: hash} do
      first = pull(hash, "pc_int")
      again = pull(hash, "pc_int")

      assert Enum.map(first["data"], & &1["id"]) == [1, 2, 3]
      assert first["truncated"] == true
      assert first["data"] == again["data"]
    end

    test "a table that fits has no mark and no cursor", %{hash: hash} do
      repo().query!("DELETE FROM pc_int WHERE id > 3")
      body = pull(hash, "pc_int")

      assert body["has_more"] == false
      refute Map.has_key?(body, "truncated")
      refute Map.has_key?(body, "next_after")
      refute Map.has_key?(body, "cursor")
    end

    test "a key type with no cursor answers its first page, marked truncated, and names the type",
         %{hash: hash} do
      repo().query!("CREATE TABLE pc_timetz (x time with time zone PRIMARY KEY)")

      repo().query!(
        "INSERT INTO pc_timetz SELECT time with time zone '00:00+00' + (g || ' minutes')::interval " <>
          "FROM generate_series(1, 10) g"
      )

      body = pull(hash, "pc_timetz", %{"paged" => true})

      assert length(body["data"]) == @limit
      assert body["truncated"] == true
      assert body["has_more"] == true
      assert body["unsupported_key_type"] == "time with time zone"
      refute Map.has_key?(body, "next_after")

      assert %{"error_code" => "invalid_cursor"} =
               hash
               |> request("pc_timetz", %{"after" => %{"x" => "00:01:00"}})
               |> json_response(400)
    end

    test "a composite key names only the types that have no cursor", %{hash: hash} do
      repo().query!("CREATE TYPE pc_mood AS ENUM ('low', 'high')")

      repo().query!(
        "CREATE TABLE pc_spans (id int, mood pc_mood, at time with time zone, alt pc_mood, " <>
          "PRIMARY KEY (id, mood, at, alt))"
      )

      repo().query!(
        "INSERT INTO pc_spans SELECT g, 'low', '00:00+00', 'high' FROM generate_series(1, 10) g"
      )

      body = pull(hash, "pc_spans", %{"paged" => true})

      assert body["truncated"] == true
      assert body["unsupported_key_type"] == "USER-DEFINED, time with time zone"
    end

    test "a table that fits names no key type, whatever its key", %{hash: hash} do
      repo().query!("CREATE TABLE pc_small (x time with time zone PRIMARY KEY)")
      repo().query!("INSERT INTO pc_small VALUES ('01:00+00')")

      body = pull(hash, "pc_small")

      assert length(body["data"]) == 1
      refute Map.has_key?(body, "truncated")
      refute Map.has_key?(body, "unsupported_key_type")
    end

    test "a key with a cursor names no key type", %{hash: hash} do
      body = pull(hash, "pc_int", %{"paged" => true})

      assert body["truncated"] == true
      assert is_map(body["next_after"])
      refute Map.has_key?(body, "unsupported_key_type")
    end

    test "a filter and a cursor apply together", %{hash: hash} do
      pages = walk(hash, "pc_int", %{"id_start" => 2, "id_end" => 9})

      assert Enum.map(pages, fn page -> Enum.map(page["data"], & &1["id"]) end) ==
               [[2, 3, 4], [5, 6, 7], [8, 9]]

      assert Enum.all?(pages, &(&1["filtered"] == true))
    end
  end

  describe "a cursor that does not fit the key" do
    setup do
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_pairs")))
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_uuid")))
      :ok
    end

    @bad_cursors [
      {"pc_pairs", "x"},
      {"pc_pairs", 5},
      {"pc_pairs", [1, 2]},
      {"pc_pairs", %{}},
      {"pc_pairs", %{"a" => "1"}},
      {"pc_pairs", %{"a" => "1", "b" => "2", "c" => "3"}},
      {"pc_pairs", %{"a" => "1", "label" => "2"}},
      {"pc_pairs", %{"a" => "x", "b" => "2"}},
      {"pc_pairs", %{"a" => "1", "b" => "2; DROP TABLE pc_pairs"}},
      {"pc_pairs", %{"a" => "1", "b" => nil}},
      {"pc_pairs", %{"a" => "1", "b" => %{"x" => 1}}},
      {"pc_pairs", %{"a" => "1", "b" => "99999999999999999999999"}},
      {"pc_uuid", %{"uuid" => "not-a-uuid"}},
      {"pc_uuid", %{"uuid" => "0190"}},
      {"pc_uuid", %{"uuid" => 5}}
    ]

    for {{table, bad}, index} <- Enum.with_index(@bad_cursors) do
      test "#{table} after=#{inspect(bad)} (case #{index}) is a 400", %{hash: hash} do
        assert %{"success" => false, "error_code" => "invalid_cursor"} =
                 hash
                 |> request(unquote(table), %{"after" => unquote(Macro.escape(bad))})
                 |> json_response(400)

        assert %{rows: [[12]]} = repo().query!("SELECT count(*) FROM pc_pairs")
      end
    end

    test "integers in the cursor read as their text", %{hash: hash} do
      body = pull(hash, "pc_pairs", %{"after" => %{"a" => 1, "b" => 3}})
      assert Enum.map(body["data"], &{&1["a"], &1["b"]}) == [{1, 4}, {2, 1}, {2, 2}]
    end
  end

  describe "what a page costs the connection" do
    setup do
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_int")))
      :ok
    end

    test "a whole table read with its cursors is one download", %{
      hash: hash,
      connection: connection
    } do
      pages = walk(hash, "pc_int")
      assert length(pages) == 4

      counted = Connections.get_connection!(connection.uuid)
      assert counted.downloads_used == 1
      assert counted.total_transfers == 1
      assert counted.records_downloaded == 10
    end

    test "so a connection with one download left can finish a table", %{
      hash: hash,
      connection: connection
    } do
      {:ok, _} = Connections.update_connection(connection, %{max_downloads: 1})

      pages = walk(hash, "pc_int")
      assert pages |> Enum.flat_map(& &1["data"]) |> length() == 10

      # ...and then has none left for another.
      assert %{"error_code" => "download_limit_reached"} =
               hash |> request("pc_int", %{}) |> json_response(403)
    end

    test "a position without this site's cursor is a new download", %{
      hash: hash,
      connection: connection
    } do
      first = pull(hash, "pc_int")
      assert downloads(connection) == 1

      # The position alone, a made-up cursor, and a real cursor moved to
      # another position or another table.
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_varchar")))
      other = pull(hash, "pc_varchar")
      assert downloads(connection) == 2

      forgeries = [
        {"pc_int", %{"after" => first["next_after"]}},
        {"pc_int", %{"after" => first["next_after"], "cursor" => "made-up"}},
        {"pc_int", %{"after" => first["next_after"], "cursor" => %{"a" => 1}}},
        {"pc_int", %{"after" => %{"id" => "0"}, "cursor" => first["cursor"]}},
        {"pc_int", %{"after" => first["next_after"], "cursor" => other["cursor"]}}
      ]

      for {{table, extra}, n} <- Enum.with_index(forgeries, 1) do
        assert pull(hash, table, extra)["success"]
        assert downloads(connection) == 2 + n, "#{inspect(extra)} was taken for a continuation"
      end
    end

    test "a page asked for again under its cursor costs no download, but its records count", %{
      hash: hash,
      connection: connection
    } do
      first = pull(hash, "pc_int")
      replay = %{"after" => first["next_after"], "cursor" => first["cursor"]}

      for n <- 1..3 do
        assert Enum.map(pull(hash, "pc_int", replay)["data"], & &1["id"]) == [4, 5, 6]

        counted = Connections.get_connection!(connection.uuid)
        assert counted.downloads_used == 1
        assert counted.records_downloaded == 3 + 3 * n
      end
    end

    test "and the record limit stops it", %{hash: hash, connection: connection} do
      {:ok, _} = Connections.update_connection(connection, %{max_records_total: 6})

      first = pull(hash, "pc_int")
      replay = %{"after" => first["next_after"], "cursor" => first["cursor"]}
      assert length(pull(hash, "pc_int", replay)["data"]) == 3

      assert %{"error_code" => "record_limit_reached"} =
               hash |> request("pc_int", replay) |> json_response(403)
    end

    # The cursor is free for the time one page takes to import, not longer.
    for {age, cost} <- [{0, 0}, {540, 0}, {660, 1}, {3_000, 1}] do
      test "a cursor signed #{age} seconds ago costs #{cost} more downloads", %{
        hash: hash,
        connection: connection
      } do
        first = pull(hash, "pc_int")
        assert downloads(connection) == 1

        aged =
          Phoenix.Token.sign(
            PhoenixKitSync.Test.Endpoint,
            "phoenix_kit_sync pull cursor",
            %{c: connection.uuid, t: "pc_int", a: first["next_after"]},
            signed_at: System.system_time(:second) - unquote(age)
          )

        body = pull(hash, "pc_int", %{"after" => first["next_after"], "cursor" => aged})

        # Old or not, the page is answered.
        assert Enum.map(body["data"], & &1["id"]) == [4, 5, 6]
        assert downloads(connection) == 1 + unquote(cost)
      end
    end

    test "a cursor is free for its own position only, earlier or later", %{
      hash: hash,
      connection: connection
    } do
      first = pull(hash, "pc_int")

      second =
        pull(hash, "pc_int", %{"after" => first["next_after"], "cursor" => first["cursor"]})

      assert downloads(connection) == 1

      # The later cursor with the earlier position (a rewind), and the
      # earlier cursor with the later position (a skip ahead).
      pull(hash, "pc_int", %{"after" => first["next_after"], "cursor" => second["cursor"]})
      assert downloads(connection) == 2

      pull(hash, "pc_int", %{"after" => second["next_after"], "cursor" => first["cursor"]})
      assert downloads(connection) == 3
    end

    test "another connection's cursor is not this connection's", %{
      hash: hash,
      connection: connection
    } do
      {:ok, other, other_token} =
        Connections.create_connection(%{
          "name" => "Other",
          "direction" => "sender",
          "site_url" => "https://other-#{System.unique_integer([:positive])}.example.com",
          "status" => "active",
          "max_records_per_request" => @limit
        })

      other_hash = :crypto.hash(:sha256, other_token) |> Base.encode16(case: :lower)
      theirs = pull(other_hash, "pc_int")
      assert downloads(other) == 1

      pull(hash, "pc_int", %{"after" => theirs["next_after"], "cursor" => theirs["cursor"]})
      assert downloads(connection) == 1
    end

    test "a forged position cannot get past a spent download limit", %{
      hash: hash,
      connection: connection
    } do
      {:ok, _} = Connections.update_connection(connection, %{max_downloads: 1})
      first = pull(hash, "pc_int")

      assert %{"error_code" => "download_limit_reached"} =
               hash
               |> request("pc_int", %{"after" => first["next_after"], "cursor" => "made-up"})
               |> json_response(403)
    end
  end

  describe "the sender's own history" do
    setup do
      create!(Enum.find(@tables, &(elem(&1, 0) == "pc_int")))
      :ok
    end

    defp sends(connection) do
      repo().all(
        from(t in Transfer,
          where: t.connection_uuid == ^connection.uuid and t.direction == "send",
          order_by: [asc: t.inserted_at, asc: t.uuid]
        )
      )
    end

    test "each page of a receiver that pages is a completed send", %{
      hash: hash,
      connection: connection
    } do
      pull(hash, "pc_int", %{"paged" => true})

      assert [%{status: "completed", records_transferred: @limit, error_message: nil} = send] =
               sends(connection)

      assert send.started_at
      assert send.completed_at
    end

    test "a cut answer to a receiver that does not page is a failed one, in one write", %{
      hash: hash,
      connection: connection
    } do
      pull(hash, "pc_int")

      assert [%{status: "failed", error_message: "sent_truncated"} = send] = sends(connection)
      assert send.records_transferred == @limit
      assert send.completed_at

      # One row, one activity: no "created" row left behind by a first write.
      assert_activity_logged("sync.transfer.failed", resource_uuid: send.uuid)

      assert %{rows: [[0]]} =
               repo().query!(
                 "SELECT count(*) FROM phoenix_kit_activities WHERE action = 'sync.transfer.created' AND resource_uuid = $1",
                 [Ecto.UUID.dump!(send.uuid)]
               )
    end
  end

  describe "a table without a primary key" do
    setup do
      repo().query!("CREATE TABLE pc_keyless (label text)")
      repo().query!("INSERT INTO pc_keyless SELECT 'r' || g FROM generate_series(1, 10) g")
      :ok
    end

    test "is refused by pull-data and table-records: its rows have no order to page in", %{
      hash: hash
    } do
      for action <- ~w(pull-data table-records) do
        response =
          post(build_conn(), "/sync/api/#{action}", %{
            "auth_token_hash" => hash,
            "table_name" => "pc_keyless"
          })

        assert %{"success" => false, "error_code" => "no_primary_key"} =
                 json_response(response, 400)
      end
    end

    test "is refused by the exporter the WebSocket path reads through" do
      assert {:error, :no_primary_key} = PhoenixKitSync.DataExporter.fetch_records("pc_keyless")

      assert {:ok, [_ | _]} =
               PhoenixKitSync.DataExporter.fetch_records("pc_keyless", order_by: "label")
    end
  end
end
