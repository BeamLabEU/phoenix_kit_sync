defmodule PhoenixKitSync.Integration.CreateTableArraysHttpTest do
  use PhoenixKitSync.ConnCase, async: false

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SchemaInspector

  # The table-schema API reports an array column as "ARRAY" with its
  # elements' type apart, so a receiver can create the table as it was.

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)

    repo = PhoenixKit.RepoHelper.repo()

    repo.query!("""
    CREATE TABLE cth_source (
      id bigint PRIMARY KEY,
      tags text[],
      codes character(3)[],
      stamps timestamp with time zone[],
      title text
    )
    """)

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Array sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://array-sender-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, _} = Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    {:ok, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp column_types(table) do
    PhoenixKit.RepoHelper.repo().query!(
      """
      SELECT c.column_name, c.data_type, c.udt_name
      FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = $1
      ORDER BY c.ordinal_position
      """,
      [table]
    ).rows
  end

  test "table-schema names an array column's element type, and a table is built from it", %{
    conn: conn,
    hash: hash
  } do
    body =
      conn
      |> post("/sync/api/table-schema", %{"auth_token_hash" => hash, "table_name" => "cth_source"})
      |> json_response(200)

    by_name = Map.new(body["schema"]["columns"], &{&1["column_name"], &1})

    assert %{"data_type" => "ARRAY", "element_type" => "text"} = by_name["tags"]
    assert %{"data_type" => "ARRAY", "element_type" => "character"} = by_name["codes"]

    assert %{"data_type" => "ARRAY", "element_type" => "timestamp with time zone"} =
             by_name["stamps"]

    assert %{"data_type" => "text", "element_type" => nil} = by_name["title"]

    assert :ok = SchemaInspector.create_table("cth_target", body["schema"])
    assert column_types("cth_target") == column_types("cth_source")
  end
end
