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

  test "ids work on a uuid key, compared as text", %{conn: conn, hash: hash} do
    repo = PhoenixKit.RepoHelper.repo()
    [a, b] = [UUIDv7.generate(), UUIDv7.generate()]

    for u <- [a, b],
        do: repo.query!("INSERT INTO pf_uuid_items VALUES ($1, 'x')", [Ecto.UUID.dump!(u)])

    body = conn |> pull(hash, "pf_uuid_items", %{"ids" => [b]}) |> json_response(200)
    assert length(body["data"]) == 1
  end

  test "a range on a non-integer key, or any filter on a composite key, is refused", %{
    conn: conn,
    hash: hash
  } do
    assert %{"success" => false, "error" => "Invalid filter"} =
             conn |> pull(hash, "pf_uuid_items", %{"id_start" => 1}) |> json_response(400)

    assert %{"success" => false} =
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
