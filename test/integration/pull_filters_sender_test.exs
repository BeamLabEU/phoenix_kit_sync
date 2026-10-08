defmodule PhoenixKitSync.Integration.PullFiltersSenderTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.Connections

  # The sender side of a filtered pull-data: only the asked-for rows,
  # "filtered": true in the answer, and the same accounting and
  # max_records_per_request cap as an unfiltered pull.

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)

    repo = PhoenixKit.RepoHelper.repo()
    repo.query!("CREATE TABLE pf_items (id bigint PRIMARY KEY, label text)")
    repo.query!("INSERT INTO pf_items SELECT g, 'item ' || g FROM generate_series(1, 6) g")
    repo.query!("CREATE TABLE pf_uuid_items (uuid uuid PRIMARY KEY, label text)")
    repo.query!("CREATE TABLE pf_pairs (a int, b int, label text, PRIMARY KEY (a, b))")
    repo.query!("CREATE TABLE pf_small (id smallint PRIMARY KEY, label text)")
    repo.query!("INSERT INTO pf_small VALUES (1, 'one'), (30000, 'big')")
    repo.query!("CREATE TABLE pf_codes (code varchar(20) PRIMARY KEY, label text)")
    repo.query!("INSERT INTO pf_codes VALUES ('a', 'A'), ('b', 'B'), ('7', 'seven')")
    repo.query!("CREATE TABLE pf_days (day date PRIMARY KEY, label text)")
    repo.query!("CREATE VIEW pf_items_view AS SELECT * FROM pf_items")
    repo.query!(~s[CREATE TABLE "PfCase" ("Order" int PRIMARY KEY, label text)])
    repo.query!(~s[INSERT INTO "PfCase" VALUES (3, 'c'), (1, 'a'), (2, 'b')])

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Filter sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://filters-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, connection} =
      Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    {:ok,
     connection: connection, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp pull(conn, hash, table, extra) do
    post(
      conn,
      "/sync/api/pull-data",
      Map.merge(%{"auth_token_hash" => hash, "table_name" => table}, extra)
    )
  end

  defp ids(body), do: body["data"] |> Enum.map(& &1["id"]) |> Enum.sort()

  test "ids select only those rows and mark the answer filtered", %{conn: conn, hash: hash} do
    body = conn |> pull(hash, "pf_items", %{"ids" => [2, 4, 99]}) |> json_response(200)

    assert body["filtered"] == true
    assert ids(body) == [2, 4]
  end

  test "an integer range selects the rows between its bounds", %{conn: conn, hash: hash} do
    body =
      conn |> pull(hash, "pf_items", %{"id_start" => 3, "id_end" => 5}) |> json_response(200)

    assert body["filtered"] == true
    assert ids(body) == [3, 4, 5]

    body = conn |> pull(hash, "pf_items", %{"id_start" => 5}) |> json_response(200)
    assert ids(body) == [5, 6]
  end

  test "without a filter the answer is as before", %{conn: conn, hash: hash} do
    body = conn |> pull(hash, "pf_items", %{}) |> json_response(200)

    refute Map.has_key?(body, "filtered")
    assert ids(body) == [1, 2, 3, 4, 5, 6]
  end

  test "ids work on a uuid key, in either case", %{conn: conn, hash: hash} do
    repo = PhoenixKit.RepoHelper.repo()
    [a, b] = [UUIDv7.generate(), UUIDv7.generate()]

    for u <- [a, b],
        do: repo.query!("INSERT INTO pf_uuid_items VALUES ($1, 'x')", [Ecto.UUID.dump!(u)])

    body =
      conn |> pull(hash, "pf_uuid_items", %{"ids" => [String.upcase(b)]}) |> json_response(200)

    assert length(body["data"]) == 1

    assert %{"error" => "Invalid filter"} =
             conn |> pull(hash, "pf_uuid_items", %{"ids" => ["not-a-uuid"]}) |> json_response(400)
  end

  test "ids work on a text key, numbers included", %{conn: conn, hash: hash} do
    body = conn |> pull(hash, "pf_codes", %{"ids" => ["b", 7]}) |> json_response(200)
    assert body["data"] |> Enum.map(& &1["label"]) |> Enum.sort() == ["B", "seven"]
  end

  test "rows come back in key order, under a quoted mixed-case keyword key", %{
    conn: conn,
    hash: hash
  } do
    body = conn |> pull(hash, "PfCase", %{"ids" => [3, 1, 2]}) |> json_response(200)
    assert Enum.map(body["data"], & &1["label"]) == ["a", "b", "c"]

    body = conn |> pull(hash, "PfCase", %{"id_start" => 2}) |> json_response(200)
    assert Enum.map(body["data"], & &1["label"]) == ["b", "c"]
  end

  test "bounds beyond a small key's type still answer, beyond int64 are refused", %{
    conn: conn,
    hash: hash
  } do
    body =
      conn |> pull(hash, "pf_small", %{"id_start" => 2, "id_end" => 40_000}) |> json_response(200)

    assert Enum.map(body["data"], & &1["label"]) == ["big"]

    body = conn |> pull(hash, "pf_small", %{"ids" => [40_000, 1]}) |> json_response(200)
    assert Enum.map(body["data"], & &1["label"]) == ["one"]

    for params <- [
          %{"id_end" => 9_223_372_036_854_775_808},
          %{"id_start" => -9_223_372_036_854_775_809}
        ] do
      assert %{"error" => "Invalid filter"} =
               conn |> pull(hash, "pf_items", params) |> json_response(400)
    end
  end

  test "a view answers a filter with 400, not as an unknown token", %{conn: conn, hash: hash} do
    body = conn |> pull(hash, "pf_items_view", %{}) |> json_response(200)
    assert length(body["data"]) == 6

    assert %{"error_code" => "filter_needs_single_key"} =
             conn |> pull(hash, "pf_items_view", %{"ids" => [1]}) |> json_response(400)
  end

  test "table-records without a filter pages in key order", %{conn: conn, hash: hash} do
    PhoenixKit.RepoHelper.repo().query!("INSERT INTO pf_codes VALUES ('0', 'zero')")

    body =
      conn
      |> post("/sync/api/table-records", %{
        "auth_token_hash" => hash,
        "table_name" => "pf_codes",
        "limit" => 2,
        "offset" => 1
      })
      |> json_response(200)

    # Keys "0", "7", "a", "b": the second page of two starts at "7".
    assert Enum.map(body["records"], & &1["label"]) == ["seven", "A"]
  end

  test "a NUL in an id is a 400, not a 500", %{conn: conn, hash: hash} do
    assert %{"error" => "Invalid filter"} =
             conn |> pull(hash, "pf_codes", %{"ids" => ["a\u0000b"]}) |> json_response(400)
  end

  test "a key type outside integer, uuid and text is refused", %{conn: conn, hash: hash} do
    assert %{"error_code" => "unsupported_key_type"} =
             conn |> pull(hash, "pf_days", %{"ids" => ["2026-01-01"]}) |> json_response(400)
  end

  test "the token is checked before the filter", %{conn: conn} do
    assert %{"success" => false} =
             conn
             |> pull(String.duplicate("b", 64), "pf_items", %{"ids" => "not a list"})
             |> json_response(401)
  end

  test "table-records takes the same filter", %{conn: conn, hash: hash} do
    records = fn extra ->
      conn
      |> post(
        "/sync/api/table-records",
        Map.merge(%{"auth_token_hash" => hash, "table_name" => "pf_codes"}, extra)
      )
    end

    body = records.(%{"ids" => ["a", 7]}) |> json_response(200)
    assert body["records"] |> Enum.map(& &1["label"]) |> Enum.sort() == ["A", "seven"]

    assert %{"error" => "Invalid filter"} = records.(%{"id_start" => 1}) |> json_response(400)
  end

  test "a range on a non-integer key, or any filter on a composite key, is refused", %{
    conn: conn,
    hash: hash
  } do
    assert %{"success" => false, "error" => "Invalid filter"} =
             conn |> pull(hash, "pf_uuid_items", %{"id_start" => 1}) |> json_response(400)

    assert %{"error_code" => "filter_needs_single_key"} =
             conn |> pull(hash, "pf_pairs", %{"ids" => [1]}) |> json_response(400)

    assert %{"success" => false} =
             conn |> pull(hash, "pf_items", %{"ids" => "1,2"}) |> json_response(400)
  end

  test "a filtered pull is counted and capped like any other", %{
    conn: conn,
    hash: hash,
    connection: connection
  } do
    {:ok, connection} =
      Connections.update_connection(connection, %{"max_records_per_request" => 2})

    body = conn |> pull(hash, "pf_items", %{"ids" => [1, 3, 5]}) |> json_response(200)
    assert body["filtered"] == true
    assert [_, _] = ids = ids(body)
    assert Enum.all?(ids, &(&1 in [1, 3, 5]))

    updated = Connections.get_connection(connection.uuid)
    assert updated.downloads_used == (connection.downloads_used || 0) + 1
    assert updated.records_downloaded == (connection.records_downloaded || 0) + 2
  end
end
