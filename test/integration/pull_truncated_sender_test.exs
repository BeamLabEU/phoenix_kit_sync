defmodule PhoenixKitSync.Integration.PullTruncatedSenderTest do
  use PhoenixKitSync.ConnCase, async: false

  import Ecto.Query

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Transfer

  # pull-data answers at most the connection's max_records_per_request rows.
  # When the table holds more, the answer says "truncated": true, so the
  # receiver can tell a cut table from a whole one.

  @limit 3

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)

    repo = PhoenixKit.RepoHelper.repo()
    repo.query!("CREATE TABLE pt_items (id bigint PRIMARY KEY, label text)")
    # Inserted out of key order, so the heap order is not the key order.
    repo.query!(
      "INSERT INTO pt_items SELECT g, 'item ' || g FROM unnest(ARRAY[8, 3, 6, 1, 5, 2, 7, 4]) g"
    )

    repo.query!("CREATE TABLE pt_exact (id bigint PRIMARY KEY, label text)")

    repo.query!(
      "INSERT INTO pt_exact SELECT g, 'item ' || g FROM generate_series(1, #{@limit}) g"
    )

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Truncating sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://truncating-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve",
        "max_records_per_request" => @limit
      })

    {:ok, connection} =
      Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    {:ok,
     connection: connection, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp pull(conn, hash, table, extra \\ %{}) do
    conn
    |> post(
      "/sync/api/pull-data",
      Map.merge(%{"auth_token_hash" => hash, "table_name" => table}, extra)
    )
    |> json_response(200)
  end

  defp ids(body), do: Enum.map(body["data"], & &1["id"])

  defp send_transfer(connection, table) do
    PhoenixKit.RepoHelper.repo().one!(
      from(t in Transfer,
        where:
          t.connection_uuid == ^connection.uuid and t.table_name == ^table and
            t.direction == "send"
      )
    )
  end

  test "a table past the limit answers the first rows by key, marked truncated", %{
    conn: conn,
    hash: hash
  } do
    body = pull(conn, hash, "pt_items")

    assert body["truncated"] == true
    assert ids(body) == [1, 2, 3]
  end

  test "a table of exactly the limit is whole, with no mark", %{conn: conn, hash: hash} do
    body = pull(conn, hash, "pt_exact")

    refute Map.has_key?(body, "truncated")
    assert ids(body) == [1, 2, 3]
  end

  test "a filtered answer past the limit is marked truncated too", %{conn: conn, hash: hash} do
    body = pull(conn, hash, "pt_items", %{"id_start" => 2})

    assert body["filtered"] == true
    assert body["truncated"] == true
    assert ids(body) == [2, 3, 4]

    body = pull(conn, hash, "pt_items", %{"id_start" => 6})
    refute Map.has_key?(body, "truncated")
    assert ids(body) == [6, 7, 8]
  end

  test "the sender's own record of a cut send is not a completed one", %{
    conn: conn,
    hash: hash,
    connection: connection
  } do
    pull(conn, hash, "pt_items")
    pull(conn, hash, "pt_exact")

    cut = send_transfer(connection, "pt_items")
    assert cut.status == "failed"
    assert cut.error_message =~ "max_records_per_request"
    assert cut.records_transferred == @limit

    whole = send_transfer(connection, "pt_exact")
    assert whole.status == "completed"
    assert whole.records_transferred == @limit
  end
end
