defmodule PhoenixKitSync.Integration.HttpTableSchemaTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  # "Create table" on the receiver builds DDL from what the sender's
  # table-schema endpoint answers. Fetched here over HTTP from the real
  # controller, then turned into a table.

  setup do
    Sandbox.mode(TestRepo, {:shared, self()})
    PhoenixKitSync.enable_system()
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    {:ok, _sender, token} =
      Connections.create_connection(%{
        "name" => "Sender side",
        "direction" => "sender",
        "site_url" => "https://receiver-#{System.unique_integer([:positive])}.example.com",
        "status" => "active"
      })

    {:ok, receiver, _token} =
      Connections.create_connection(%{
        "name" => "Receiver side",
        "direction" => "receiver",
        "site_url" => "http://localhost:#{port}",
        "auth_token" => token,
        "status" => "active"
      })

    repo().query!("""
    CREATE TABLE hts_source (
      id bigint PRIMARY KEY,
      name varchar(40) NOT NULL,
      tags text[],
      refs uuid[],
      scores integer[],
      labels varchar(20)[],
      payload jsonb
    )
    """)

    {:ok, receiver: receiver, hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp column_types(table) do
    %{rows: rows} =
      repo().query!(
        "SELECT column_name, data_type, udt_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = $1 ORDER BY ordinal_position",
        [table]
      )

    rows
  end

  test "a table with array columns can be created from the schema the API sends", %{
    receiver: receiver
  } do
    assert {:ok, schema} = ConnectionNotifier.fetch_table_schema(receiver, "hts_source")

    by_name = Map.new(schema["columns"], &{&1["name"], &1})
    # An array column arrives as its element type with brackets: the bare
    # "ARRAY" information_schema reports is not a type DDL can use.
    assert by_name["tags"]["type"] == "text[]"
    assert by_name["refs"]["type"] == "uuid[]"
    assert by_name["scores"]["type"] == "integer[]"
    assert by_name["labels"]["type"] == "character varying[]"
    assert by_name["payload"]["type"] == "jsonb"
    assert schema["primary_key"] == ["id"]

    assert :ok = SchemaInspector.create_table("hts_copy", schema)

    strip_names = fn rows ->
      Enum.map(rows, fn [name, type, udt, null] -> {name, type, udt, null} end)
    end

    assert strip_names.(column_types("hts_copy")) ==
             strip_names.(column_types("hts_source"))

    assert {:ok, ["id"]} = SchemaInspector.get_primary_key("hts_copy")
  end

  test "each column carries the element type and the names receivers have always read", %{
    hash: hash
  } do
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    {:ok, %Finch.Response{status: 200, body: body}} =
      :post
      |> Finch.build(
        "http://localhost:#{port}/sync/api/table-schema",
        [{"content-type", "application/json"}],
        Jason.encode!(%{"auth_token_hash" => hash, "table_name" => "hts_source"})
      )
      |> Finch.request(PhoenixKit.Finch)

    %{"success" => true, "schema" => schema} = Jason.decode!(body)
    by_name = Map.new(schema["columns"], &{&1["column_name"], &1})

    assert %{
             "column_name" => "name",
             "data_type" => "character varying",
             "is_nullable" => "NO",
             "character_maximum_length" => 40,
             "column_default" => nil,
             "name" => "name",
             "type" => "character varying",
             "nullable" => false,
             "element_type" => nil
           } = by_name["name"]

    assert %{"data_type" => "ARRAY", "type" => "ARRAY", "element_type" => "uuid"} =
             by_name["refs"]

    assert %{"is_nullable" => "YES", "primary_key" => false} = by_name["tags"]
    assert %{"primary_key" => true} = by_name["id"]
  end

  test "a view still answers its columns", %{receiver: receiver} do
    repo().query!("CREATE VIEW hts_view AS SELECT id, name FROM hts_source")

    assert {:ok, schema} = ConnectionNotifier.fetch_table_schema(receiver, "hts_view")
    assert Enum.map(schema["columns"], & &1["name"]) == ["id", "name"]
  end
end
