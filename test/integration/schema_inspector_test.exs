defmodule PhoenixKitSync.Integration.SchemaInspectorTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.Repo

  # ===========================================
  # table_exists?/1
  # ===========================================

  describe "table_exists?/1" do
    test "returns true for an existing sync table" do
      assert SchemaInspector.table_exists?("phoenix_kit_sync_connections")
    end

    test "returns false for a nonexistent table" do
      refute SchemaInspector.table_exists?("nonexistent_table_xyz")
    end
  end

  # ===========================================
  # list_tables/0
  # ===========================================

  describe "list_tables/0" do
    test "returns a non-empty list of tables" do
      assert {:ok, tables} = SchemaInspector.list_tables()
      assert is_list(tables)
      assert tables != []
    end

    test "each entry has a :name key" do
      {:ok, tables} = SchemaInspector.list_tables()

      Enum.each(tables, fn table ->
        assert Map.has_key?(table, :name)
        assert is_binary(table.name)
      end)
    end

    test "includes phoenix_kit_sync tables by default" do
      {:ok, tables} = SchemaInspector.list_tables()
      table_names = Enum.map(tables, & &1.name)
      assert "phoenix_kit_sync_connections" in table_names
    end

    test "each entry has an :estimated_count key" do
      {:ok, tables} = SchemaInspector.list_tables()

      Enum.each(tables, fn table ->
        assert Map.has_key?(table, :estimated_count)
        assert is_integer(table.estimated_count)
      end)
    end
  end

  # ===========================================
  # get_schema/1
  # ===========================================

  describe "get_schema/1" do
    test "returns schema for connections table with columns list" do
      assert {:ok, schema} = SchemaInspector.get_schema("phoenix_kit_sync_connections")
      assert schema.table == "phoenix_kit_sync_connections"
      assert is_list(schema.columns)
      assert schema.columns != []
    end

    test "primary_key includes uuid" do
      {:ok, schema} = SchemaInspector.get_schema("phoenix_kit_sync_connections")
      assert "uuid" in schema.primary_key
    end

    test "returns error for nonexistent table" do
      assert {:error, :not_found} = SchemaInspector.get_schema("nonexistent_table_xyz")
    end
  end

  # ===========================================
  # get_primary_key/1
  # ===========================================

  describe "get_primary_key/1" do
    test "returns [\"uuid\"] for connections table" do
      assert {:ok, ["uuid"]} = SchemaInspector.get_primary_key("phoenix_kit_sync_connections")
    end
  end

  # ===========================================
  # get_local_count/1
  # ===========================================

  describe "get_local_count/1" do
    test "returns {:ok, count} where count >= 0 for connections table" do
      assert {:ok, count} = SchemaInspector.get_local_count("phoenix_kit_sync_connections")
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ===========================================
  # get_table_checksum/1
  # ===========================================

  describe "get_table_checksum/1" do
    test "returns {:ok, \"empty\"} for an empty table" do
      assert {:ok, "empty"} = SchemaInspector.get_table_checksum("phoenix_kit_sync_connections")
    end

    test "returns {:ok, checksum_string} after inserting data" do
      alias PhoenixKitSync.Connections

      {:ok, _conn, _token} =
        Connections.create_connection(%{
          "name" => "Checksum Test",
          "direction" => "sender",
          "site_url" => "https://checksum-#{System.unique_integer([:positive])}.com"
        })

      assert {:ok, checksum} = SchemaInspector.get_table_checksum("phoenix_kit_sync_connections")
      assert is_binary(checksum)
      assert checksum != "empty"
    end
  end

  # ===========================================
  # get_all_foreign_keys/0
  # ===========================================

  describe "get_all_foreign_keys/0" do
    test "returns a map" do
      assert {:ok, fk_map} = SchemaInspector.get_all_foreign_keys()
      assert is_map(fk_map)
    end
  end

  # ===========================================
  # create_table/2
  # ===========================================

  describe "create_table/2" do
    test "creates a new table from schema definition" do
      table_name = "sync_test_create_#{System.unique_integer([:positive])}"

      schema_def = %{
        "columns" => [
          %{"name" => "id", "type" => "bigint", "nullable" => false, "primary_key" => true},
          %{"name" => "title", "type" => "character varying", "nullable" => true}
        ],
        "primary_key" => ["id"]
      }

      assert :ok = SchemaInspector.create_table(table_name, schema_def)
      assert SchemaInspector.table_exists?(table_name)

      # Cleanup
      Repo.query!("DROP TABLE IF EXISTS \"#{table_name}\"")
    end

    test "returns error for invalid table name" do
      assert {:error, :invalid_table_name} =
               SchemaInspector.create_table("invalid--name!", %{"columns" => []})
    end
  end
end
