defmodule PhoenixKitSync.Integration.BinaryValuesRoundTripTest do
  use PhoenixKitSync.DataCase, async: false

  import Phoenix.ConnTest

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter

  @endpoint PhoenixKitSync.Test.Endpoint

  # Records travel as JSON over the WebSocket and Channel paths. Postgrex
  # hands uuid and bytea columns over as raw bytes, which JSON cannot carry,
  # and numeric as Decimal; the exporter has to put them in a JSON form and
  # the importer has to read that form back into the column's type.

  @columns """
  uuid uuid PRIMARY KEY,
  parent_uuid uuid,
  blob bytea,
  amount numeric(12, 2),
  label text
  """

  setup do
    repo().query!("CREATE TABLE IF NOT EXISTS rt_source (#{@columns})")
    repo().query!("CREATE TABLE IF NOT EXISTS rt_target (#{@columns})")

    [a, b] = [UUIDv7.generate(), UUIDv7.generate()]

    repo().query!(
      "INSERT INTO rt_source VALUES ($1, $2, $3, $4, 'first'), ($2, NULL, NULL, NULL, 'second')",
      [Ecto.UUID.dump!(a), Ecto.UUID.dump!(b), <<0, 255, 1, 254>>, Decimal.new("12.50")]
    )

    {:ok, a: a, b: b}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp rows(table) do
    repo().query!(
      "SELECT uuid::text, parent_uuid::text, blob, amount::text, label FROM #{table} ORDER BY label"
    ).rows
  end

  test "exported records encode as JSON, uuids as their text", %{a: a, b: b} do
    {:ok, records} = DataExporter.fetch_records("rt_source")

    assert {:ok, _json} = Jason.encode(records)

    first = Enum.find(records, &(&1["label"] == "first"))
    assert first["uuid"] == a
    assert first["parent_uuid"] == b
    assert first["blob"] == %{"__phoenix_kit_binary__" => Base.encode64(<<0, 255, 1, 254>>)}
    assert first["amount"] == "12.50"
  end

  test "export -> JSON -> import reproduces the rows" do
    {:ok, records} = DataExporter.fetch_records("rt_source")
    records = records |> Jason.encode!() |> Jason.decode!()

    assert {:ok, %{created: 2, errors: []}} = DataImporter.import_records("rt_target", records)
    assert rows("rt_target") == rows("rt_source")
  end

  test "a second import of the same rows finds them by their uuid key" do
    {:ok, records} = DataExporter.fetch_records("rt_source")
    records = records |> Jason.encode!() |> Jason.decode!()

    {:ok, _} = DataImporter.import_records("rt_target", records)

    assert {:ok, %{created: 0, skipped: 2, errors: []}} =
             DataImporter.import_records("rt_target", records, :skip)
  end

  test "records in an older sender's form still import", %{a: a, b: b} do
    # The HTTP API wraps a uuid's bytes in base64; a numeric came as a
    # string; a uuid may also come as plain text.
    wrap = &%{"__phoenix_kit_binary__" => Base.encode64(&1)}

    records = [
      %{
        "uuid" => wrap.(Ecto.UUID.dump!(a)),
        "parent_uuid" => b,
        "blob" => wrap.(<<0, 255, 1, 254>>),
        "amount" => "12.50",
        "label" => "first"
      },
      %{"uuid" => b, "parent_uuid" => nil, "blob" => nil, "amount" => nil, "label" => "second"}
    ]

    assert {:ok, %{created: 2, errors: []}} = DataImporter.import_records("rt_target", records)
    assert rows("rt_target") == rows("rt_source")
  end

  test "bytes are wrapped the same way on the HTTP API and the export paths" do
    PhoenixKitSync.enable_system()

    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Wrap check #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://wrap-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, _} = Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    http =
      build_conn()
      |> post("/sync/api/pull-data", %{
        "auth_token_hash" => :crypto.hash(:sha256, token) |> Base.encode16(case: :lower),
        "table_name" => "rt_source"
      })
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.find(&(&1["label"] == "first"))

    {:ok, exported} = DataExporter.fetch_records("rt_source")

    exported =
      exported |> Jason.encode!() |> Jason.decode!() |> Enum.find(&(&1["label"] == "first"))

    assert http["blob"] == exported["blob"]
    assert %{"__phoenix_kit_binary__" => _} = exported["blob"]
  end
end
