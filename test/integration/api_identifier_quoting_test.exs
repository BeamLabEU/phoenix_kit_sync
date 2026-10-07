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

  test "table-schema includes the primary key", %{conn: conn, hash: hash} do
    body =
      conn
      |> post("/sync/api/table-schema", %{"auth_token_hash" => hash, "table_name" => "ApiCase"})
      |> json_response(200)

    assert body["schema"]["primary_key"] == ["id"]
  end
end
