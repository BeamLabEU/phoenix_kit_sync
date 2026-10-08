defmodule PhoenixKitSync.Integration.ArrayValuesRoundTripTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter

  # Array columns travel as JSON lists over the WebSocket and Channel paths.
  # Each element follows its scalar rule: a uuid goes as its text, bytes
  # wrapped, json as its term; the importer reads every element back by the
  # array's element type.

  @columns """
  uuid uuid PRIMARY KEY,
  label text,
  tags text[],
  names varchar(20)[],
  refs uuid[],
  nums int[],
  grid int[][],
  ref_grid uuid[][],
  amounts numeric[],
  docs jsonb[],
  doc_lists jsonb[],
  blobs bytea[],
  days date[],
  dom_refs ar_uuid_list
  """

  # 16 raw bytes that happen to be UTF-8 ("AAAA…") and 16 that are not:
  # neither may decide how a uuid element travels.
  @text_uuid "41414141-4141-4141-4141-414141414141"
  @raw_uuid "0192a8b4-7c3e-7d4f-8a5b-6c7d8e9f0a1b"
  @big "123456789012345678901234567890.123456789"

  setup do
    # A domain over an array is reported as the array it wraps.
    repo().query!("CREATE DOMAIN ar_uuid_list AS uuid[]")
    repo().query!("CREATE TABLE IF NOT EXISTS ar_source (#{@columns})")
    repo().query!("CREATE TABLE IF NOT EXISTS ar_target (#{@columns})")

    repo().query!(
      """
      INSERT INTO ar_source VALUES
        ($1, 'full',
         ARRAY['a', '2025-01-01', '12:30:00', NULL],
         ARRAY['x', NULL]::varchar(20)[],
         ARRAY['#{@text_uuid}', NULL, '#{@raw_uuid}']::uuid[],
         ARRAY[1, NULL, 3],
         ARRAY[[1, 2], [3, NULL]],
         ARRAY[['#{@text_uuid}', NULL], ['#{@raw_uuid}', '#{@text_uuid}']]::uuid[][],
         ARRAY[12.50, NULL, #{@big}]::numeric[],
         ARRAY['{"k": "v"}', '"s"', NULL, '42', '{"__phoenix_kit_binary__": "AAE="}']::jsonb[],
         ARRAY['[1, 2]', '[3, 4]']::jsonb[],
         ARRAY['\\x00ff'::bytea, '\\x6869'::bytea, NULL],
         ARRAY['2025-01-01'::date, NULL],
         ARRAY['#{@text_uuid}', '#{@raw_uuid}']::uuid[]),
        ($2, 'empty', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}'),
        ($3, 'nulls', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
      """,
      Enum.map(1..3, fn _ -> Ecto.UUID.dump!(UUIDv7.generate()) end)
    )

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp rows(table) do
    repo().query!("""
    SELECT label, tags::text, names::text, refs::text, nums::text, grid::text, ref_grid::text,
           amounts::text, docs::text, doc_lists::text, blobs::text, days::text, dom_refs::text
    FROM #{table} ORDER BY label
    """).rows
  end

  defp exported(label) do
    {:ok, records} = DataExporter.fetch_records("ar_source")
    records |> Jason.encode!() |> Jason.decode!() |> Enum.find(&(&1["label"] == label))
  end

  test "array elements are exported by the array's element type" do
    full = exported("full")

    assert full["refs"] == [@text_uuid, nil, @raw_uuid]
    assert full["dom_refs"] == [@text_uuid, @raw_uuid]
    assert full["blobs"] == [%{"__phoenix_kit_binary__" => Base.encode64(<<0, 255>>)}, "hi", nil]
    assert full["docs"] == [%{"k" => "v"}, "s", nil, 42, %{"__phoenix_kit_binary__" => "AAE="}]
    assert full["grid"] == [[1, 2], [3, nil]]
    # A jsonb[] of JSON arrays looks like a two-dimensional array on the wire;
    # the importer keeps each JSON array one element.
    assert full["doc_lists"] == [[1, 2], [3, 4]]
    assert full["ref_grid"] == [[@text_uuid, nil], [@raw_uuid, @text_uuid]]
    assert full["amounts"] == ["12.50", nil, @big]
    assert exported("empty")["refs"] == []
  end

  test "export -> JSON -> import reproduces the rows" do
    {:ok, records} = DataExporter.fetch_records("ar_source")
    records = records |> Jason.encode!() |> Jason.decode!()

    assert {:ok, %{created: 3, errors: []}} = DataImporter.import_records("ar_target", records)
    assert rows("ar_target") == rows("ar_source")
  end

  test "uuid and bytea elements in an older sender's form still import" do
    # Before element types, a uuid element went wrapped when its 16 bytes
    # were not UTF-8 and as those raw bytes when they were.
    wrap = &%{"__phoenix_kit_binary__" => Base.encode64(&1)}

    record =
      "full"
      |> exported()
      |> Map.put("refs", [Ecto.UUID.dump!(@text_uuid), nil, wrap.(Ecto.UUID.dump!(@raw_uuid))])

    assert {:ok, %{created: 1, errors: []}} = DataImporter.import_records("ar_target", [record])
    assert rows("ar_target") == Enum.filter(rows("ar_source"), &(hd(&1) == "full"))
  end
end
