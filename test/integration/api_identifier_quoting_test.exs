defmodule PhoenixKitSync.Integration.ApiIdentifierQuotingTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.Connections

  # The sender reads tables by the name the receiver asks for. Unquoted,
  # Postgres folds that name to lower case: "ApiCase" would read "apicase",
  # a different table the connection may exclude, and a table named like a
  # keyword would not parse at all.

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)

    repo = PhoenixKit.RepoHelper.repo()
    repo.query!(~s[CREATE TABLE "ApiCase" (id int PRIMARY KEY, label text)])
    repo.query!(~s[INSERT INTO "ApiCase" VALUES (1, 'mixed-case table')])
    repo.query!(~s[CREATE TABLE apicase (id int PRIMARY KEY, label text)])
    repo.query!(~s[INSERT INTO apicase VALUES (1, 'excluded twin')])
    repo.query!(~s[CREATE TABLE "order" (id int PRIMARY KEY, label text)])
    repo.query!(~s[CREATE TABLE "QPk" ("Id" int PRIMARY KEY, label text)])
    repo.query!(~s[INSERT INTO "QPk" VALUES (3, 'c'), (1, 'a'), (2, 'b'), (4, 'd')])
    repo.query!(~s[CREATE TABLE quoted_key ("a""b" int PRIMARY KEY, label text)])
    repo.query!(~s[INSERT INTO quoted_key VALUES (2, 'two'), (1, 'one')])
    repo.query!(~s[INSERT INTO "order" VALUES (1, 'keyword table')])

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Quoting sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://quoting-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, connection} =
      Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    {:ok, _} = Connections.update_connection(connection, %{"excluded_tables" => ["apicase"]})

    {:ok, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp labels(body, key), do: Enum.map(body[key], & &1["label"])

  test "pull-data reads the exact table asked for, not its lower-case twin", %{
    conn: conn,
    hash: hash
  } do
    body =
      conn
      |> post("/sync/api/pull-data", %{"auth_token_hash" => hash, "table_name" => "ApiCase"})
      |> json_response(200)

    assert labels(body, "data") == ["mixed-case table"]
  end

  test "table-records reads the exact table too", %{conn: conn, hash: hash} do
    body =
      conn
      |> post("/sync/api/table-records", %{
        "auth_token_hash" => hash,
        "table_name" => "ApiCase",
        "ids" => [1]
      })
      |> json_response(200)

    assert labels(body, "records") == ["mixed-case table"]
  end

  test "a table named like a keyword can be pulled", %{conn: conn, hash: hash} do
    body =
      conn
      |> post("/sync/api/pull-data", %{"auth_token_hash" => hash, "table_name" => "order"})
      |> json_response(200)

    assert labels(body, "data") == ["keyword table"]

    body =
      conn
      |> post("/sync/api/table-records", %{"auth_token_hash" => hash, "table_name" => "order"})
      |> json_response(200)

    assert labels(body, "records") == ["keyword table"]
  end

  defp records(conn, hash, table, extra) do
    conn
    |> post(
      "/sync/api/table-records",
      Map.merge(%{"auth_token_hash" => hash, "table_name" => table}, extra)
    )
    |> json_response(200)
    |> Map.fetch!("records")
    |> Enum.map(& &1["label"])
  end

  test "a mixed-case key is ordered, filtered and counted by its own name", %{
    conn: conn,
    hash: hash
  } do
    assert records(conn, hash, "QPk", %{"limit" => 2, "offset" => 1}) == ["b", "c"]
    assert records(conn, hash, "QPk", %{"ids" => [4, 1]}) == ["a", "d"]
    assert records(conn, hash, "QPk", %{"id_start" => 2, "id_end" => 3}) == ["b", "c"]

    tables =
      conn
      |> post("/sync/api/list-tables", %{"auth_token_hash" => hash})
      |> json_response(200)
      |> Map.fetch!("tables")

    assert %{"row_count" => 4} = Enum.find(tables, &(&1["name"] == "QPk"))
  end

  test "a quote inside a key name is escaped", %{conn: conn, hash: hash} do
    assert records(conn, hash, "quoted_key", %{}) == ["one", "two"]
  end

  test "table-schema includes the primary key", %{conn: conn, hash: hash} do
    body =
      conn
      |> post("/sync/api/table-schema", %{"auth_token_hash" => hash, "table_name" => "ApiCase"})
      |> json_response(200)

    assert body["schema"]["primary_key"] == ["id"]
  end
end
