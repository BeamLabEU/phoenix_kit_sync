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
  label text,
  note text,
  big numeric,
  doc jsonb,
  doc_json json
  """

  # Values whose JSON form says nothing about their column's type: the
  # importer has to read each one by the column it lands in, not by its shape.
  @typed_rows [
    # 16 bytes in a bytea column are not a uuid; a uuid's text in a text
    # column stays text; json objects and arrays stay json, not json strings.
    {"typed", <<0, 255, 1, 254, 2, 253, 3, 252, 4, 251, 5, 250, 6, 249, 7, 248>>,
     "0192a8b4-7c3e-7d4f-8a5b-6c7d8e9f0a1b", nil, ~s({"k": "v", "n": 1}), ~s({"k": "v", "n": 1})},
    # bytea that happens to be UTF-8 text shaped like a date or a time stays bytes.
    {"date-bytes", "2025-01-01", nil, nil, ~s([1, "a", {"b": null}]), ~s([1, "a", {"b": null}])},
    {"time-bytes", "12:30:00", nil, nil, ~s("hello"), ~s("hello")},
    {"json-number", nil, nil, nil, "42.5", "42"},
    # A numeric past decimal128's 34 significant digits, which Decimal.parse/1
    # refuses by default; numeric itself holds far more.
    {"big-numeric", nil, nil, "123456789012345678901234567890.123456789", nil, nil},
    # The sign survives, on a short numeric and a long one alike.
    {"neg-numeric", nil, nil, "-12.50", nil, nil},
    {"neg-big-numeric", nil, nil, "-123456789012345678901234567890.123456789", nil, nil},
    # A tiny numeric past 34 digits, which the exporter writes in scientific
    # form ("1.2345…E-8").
    {"tiny-numeric", nil, nil, "0.0000000123456789012345678901234567890123456789", nil, nil},
    # A json object that happens to use the bytes wrapper's key is still an object.
    {"json-wrapper-key", nil, nil, nil, ~s({"__phoenix_kit_binary__": "AAE="}),
     ~s({"__phoenix_kit_binary__": "AAE="})}
  ]

  setup do
    repo().query!("CREATE TABLE IF NOT EXISTS rt_source (#{@columns})")
    repo().query!("CREATE TABLE IF NOT EXISTS rt_target (#{@columns})")

    [a, b] = [UUIDv7.generate(), UUIDv7.generate()]

    repo().query!(
      "INSERT INTO rt_source VALUES ($1, $2, $3, $4, 'first'), ($2, NULL, NULL, NULL, 'second')",
      [Ecto.UUID.dump!(a), Ecto.UUID.dump!(b), <<0, 255, 1, 254>>, Decimal.new("12.50")]
    )

    for {label, blob, note, big, doc, doc_json} <- @typed_rows do
      repo().query!(
        "INSERT INTO rt_source (uuid, label, blob, note, big, doc, doc_json) " <>
          "VALUES ($1, $2, $3, $4, $5::text::numeric, $6::text::jsonb, $7::text::json)",
        [Ecto.UUID.dump!(UUIDv7.generate()), label, blob, note, big, doc, doc_json]
      )
    end

    {:ok, a: a, b: b}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp rows(table) do
    repo().query!("""
    SELECT uuid::text, parent_uuid::text, blob, amount::text, label,
           note, big::text, doc::text, doc_json::jsonb::text
    FROM #{table} ORDER BY label
    """).rows
  end

  defp rows(table, labels), do: Enum.filter(rows(table), &(Enum.at(&1, 4) in labels))

  test "a tiny numeric past 34 digits is exported in scientific form" do
    {:ok, records} = DataExporter.fetch_records("rt_source")
    tiny = Enum.find(records, &(&1["label"] == "tiny-numeric"))

    assert tiny["big"] == "1.23456789012345678901234567890123456789E-8"
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

    assert {:ok, %{created: 11, errors: []}} = DataImporter.import_records("rt_target", records)
    assert rows("rt_target") == rows("rt_source")
  end

  test "typed values are exported by their column's type" do
    {:ok, records} = DataExporter.fetch_records("rt_source")
    typed = Enum.find(records, &(&1["label"] == "typed"))

    assert typed["blob"] == %{
             "__phoenix_kit_binary__" =>
               Base.encode64(<<0, 255, 1, 254, 2, 253, 3, 252, 4, 251, 5, 250, 6, 249, 7, 248>>)
           }

    assert typed["note"] == "0192a8b4-7c3e-7d4f-8a5b-6c7d8e9f0a1b"
    assert typed["doc"] == %{"k" => "v", "n" => 1}
  end

  # The exporter cannot write a numeric past Decimal's 6178 output digits,
  # and a numeric's scale stops at 16383; anything beyond is a peer's load,
  # not data, and fails that record alone.
  defp numeric_import(values) do
    records =
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, i} ->
        %{"uuid" => UUIDv7.generate(), "label" => "n#{i}", "big" => value}
      end)

    DataImporter.import_records("rt_target", records)
  end

  defp numeric_stored?(value) do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM rt_target WHERE big = $1::text::numeric", [value])

    count == 1
  end

  test "a numeric string within the exporter's limits imports" do
    values = [
      "1" <> String.duplicate("0", 6177),
      "-" <> String.duplicate("9", 6178),
      "0." <> String.duplicate("0", 16_382) <> "1",
      "2E+6177",
      "2E-16383",
      "-1.5E+3",
      "1.23456789012345678901234567890123456789E-8"
    ]

    assert {:ok, %{created: 7, errors: []}} = numeric_import(values)
    assert Enum.all?(values, &numeric_stored?/1)
  end

  test "a numeric string past the exporter's limits fails its record only" do
    values = [
      "1" <> String.duplicate("0", 6178),
      "0." <> String.duplicate("0", 16_383) <> "1",
      "1E+6178",
      "1E-16384",
      "12.50"
    ]

    assert {:ok, %{created: 1, errors: [_, _, _, _]}} = numeric_import(values)
    assert numeric_stored?("12.50")
  end

  test "a second import of the same rows finds them by their uuid key" do
    {:ok, records} = DataExporter.fetch_records("rt_source")
    records = records |> Jason.encode!() |> Jason.decode!()

    {:ok, _} = DataImporter.import_records("rt_target", records)

    assert {:ok, %{created: 0, skipped: 11, errors: []}} =
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
    assert rows("rt_target") == rows("rt_source", ["first", "second"])
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
