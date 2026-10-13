defmodule PhoenixKitSync.Integration.CreateTableArraysTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.SchemaInspector

  # A receiver creates a missing table from the sender's schema, which
  # reports every array column as "ARRAY" and its elements' type apart.

  @columns """
  uuid uuid PRIMARY KEY,
  tags text[] NOT NULL DEFAULT '{}',
  names varchar(20)[],
  refs uuid[],
  grid int[][],
  docs jsonb[],
  stamps timestamp with time zone[],
  codes character(3)[],
  flags bit varying(8)[],
  spans int4range[],
  periods daterange[],
  words tsvector[]
  """

  setup do
    repo().query!("CREATE TABLE ct_source (#{@columns})")

    repo().query!(
      """
      INSERT INTO ct_source VALUES
        ($1, ARRAY['a', NULL], ARRAY['x'], ARRAY['#{UUIDv7.generate()}']::uuid[],
         ARRAY[[1, 2], [3, 4]], ARRAY['{"k": 1}']::jsonb[],
         ARRAY['2025-01-01 12:00:00+00']::timestamptz[], ARRAY['abc']),
        ($2, '{}', NULL, NULL, NULL, NULL, NULL, NULL)
      """,
      [Ecto.UUID.dump!(UUIDv7.generate()), Ecto.UUID.dump!(UUIDv7.generate())]
    )

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # The schema as a receiver gets it over the wire.
  defp wire_schema(table) do
    {:ok, schema} = SchemaInspector.get_schema(table)
    schema |> Jason.encode!() |> Jason.decode!()
  end

  defp column_types(table) do
    repo().query!(
      """
      SELECT c.column_name, c.data_type, c.udt_name, e.data_type, c.is_nullable
      FROM information_schema.columns c
      LEFT JOIN information_schema.element_types e
        ON (c.table_catalog, c.table_schema, c.table_name, 'TABLE', c.dtd_identifier) =
           (e.object_catalog, e.object_schema, e.object_name, e.object_type,
            e.collection_type_identifier)
      WHERE c.table_schema = 'public' AND c.table_name = $1
      ORDER BY c.ordinal_position
      """,
      [table]
    ).rows
  end

  defp rows(table) do
    repo().query!(
      "SELECT uuid::text, tags::text, names::text, refs::text, grid::text, docs::text, " <>
        "stamps::text, codes::text FROM #{table} ORDER BY uuid"
    ).rows
  end

  test "array columns are created with their element types" do
    assert :ok = SchemaInspector.create_table("ct_target", wire_schema("ct_source"))
    assert column_types("ct_target") == column_types("ct_source")
  end

  test "a table created from the schema takes the source's rows" do
    :ok = SchemaInspector.create_table("ct_target", wire_schema("ct_source"))

    {:ok, records} = DataExporter.fetch_records("ct_source")
    records = records |> Jason.encode!() |> Jason.decode!()

    assert {:ok, %{created: 2, errors: []}} = DataImporter.import_records("ct_target", records)
    assert rows("ct_target") == rows("ct_source")
  end

  test "an element type off the allowlist never reaches the DDL" do
    # After the identifier checks, element_type is the only sender string
    # spelled into the DDL. valid_column_type?/1 guards its syntax; the
    # allowlist is what keeps it to the types a table can be created with.
    repo().query!("CREATE TABLE ct_victim (id int)")
    schema = wire_schema("ct_source")
    hostile = "text[], x text); DROP TABLE ct_victim; --"

    columns =
      Enum.map(schema["columns"], fn
        %{"name" => "tags"} = col -> %{col | "element_type" => hostile}
        col -> col
      end)

    assert {:error, :unsupported_column_type} =
             SchemaInspector.create_table("ct_target", %{schema | "columns" => columns})

    assert SchemaInspector.table_exists?("ct_victim")
    refute SchemaInspector.table_exists?("ct_target")
  end

  test "a bad table name is refused as such before any column is looked at" do
    schema = wire_schema("ct_source")
    columns = Enum.map(schema["columns"], &Map.delete(&1, "element_type"))

    assert {:error, :invalid_table_name} =
             SchemaInspector.create_table("ct target", %{schema | "columns" => columns})
  end

  test "an array column without a known element type is refused, not sent as DDL" do
    # Senders before element types report only "ARRAY".
    schema = wire_schema("ct_source")
    columns = Enum.map(schema["columns"], &Map.delete(&1, "element_type"))

    assert {:error, :invalid_column_type} =
             SchemaInspector.create_table("ct_target", %{schema | "columns" => columns})

    refute SchemaInspector.table_exists?("ct_target")
  end

  test "a user-defined column type is refused, not sent as DDL" do
    repo().query!("CREATE TYPE ct_mood AS ENUM ('calm', 'busy')")
    repo().query!("CREATE TABLE ct_moods (uuid uuid PRIMARY KEY, mood ct_mood)")
    repo().query!("CREATE TABLE ct_mood_lists (uuid uuid PRIMARY KEY, moods ct_mood[])")

    assert {:error, :unsupported_column_type} =
             SchemaInspector.create_table("ct_target", wire_schema("ct_moods"))

    # An array of one: its element type is not on the allowlist.
    assert {:error, :unsupported_column_type} =
             SchemaInspector.create_table("ct_target", wire_schema("ct_mood_lists"))

    refute SchemaInspector.table_exists?("ct_target")
  end

  test "an array of a type off the allowlist is refused, even a plain name" do
    # Each is a valid type name: valid_column_type?/1 passes it, so only the
    # allowlist stops the table.
    for element <- ~w(oid name point tsquery pg_class) do
      assert {:error, :unsupported_column_type} =
               SchemaInspector.create_table("ct_target", %{
                 "columns" => [
                   %{"name" => "id", "type" => "bigint", "nullable" => false},
                   %{"name" => "xs", "type" => "#{element}[]", "nullable" => true}
                 ],
                 "primary_key" => ["id"]
               }),
             "#{element}[] was not refused"
    end

    refute SchemaInspector.table_exists?("ct_target")
  end

  test "a column type that is no string is refused as an invalid type, not a crash" do
    # JSON null, a number, a list and an object all reach create_table from
    # a sender's answer.
    for type <- [nil, 5, ["text"], %{"a" => 1}] do
      assert {:error, :invalid_column_type} =
               SchemaInspector.create_table("ct_target", %{
                 "columns" => [%{"name" => "xs", "type" => type, "nullable" => true}],
                 "primary_key" => []
               }),
             "#{inspect(type)} was not refused"
    end

    refute SchemaInspector.table_exists?("ct_target")
  end

  test "a long run of array brackets is refused in linear time" do
    # One shape puts the run before the last character, one makes it the
    # type's whole tail, which the check peels bracket by bracket.
    for type <- [String.duplicate("[]", 20_000) <> "x", "x" <> String.duplicate("[]", 20_000)] do
      {microseconds, result} =
        :timer.tc(fn ->
          SchemaInspector.create_table("ct_target", %{
            "columns" => [%{"name" => "xs", "type" => type, "nullable" => true}],
            "primary_key" => []
          })
        end)

      assert {:error, _reason} = result
      assert microseconds < 100_000, "took #{microseconds} microseconds"
    end
  end
end
