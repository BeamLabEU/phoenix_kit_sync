defmodule PhoenixKitSync.Integration.DataExporterTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter

  defp create_test_connection do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "Export Test",
        "direction" => "sender",
        "site_url" => "https://export-test-#{System.unique_integer([:positive])}.com"
      })

    conn
  end

  # ===========================================
  # get_count/1
  # ===========================================

  describe "get_count/1" do
    test "returns {:ok, 0} for empty connections table" do
      assert {:ok, 0} = DataExporter.get_count("phoenix_kit_sync_connections")
    end

    test "returns {:error, :table_not_found} for non-existent table" do
      assert {:error, :table_not_found} = DataExporter.get_count("nonexistent_table_xyz")
    end

    test "returns {:ok, 1} after inserting a connection" do
      _conn = create_test_connection()
      assert {:ok, 1} = DataExporter.get_count("phoenix_kit_sync_connections")
    end
  end

  # ===========================================
  # fetch_records/1
  # ===========================================

  describe "fetch_records/1" do
    test "returns {:ok, []} for empty table" do
      assert {:ok, []} = DataExporter.fetch_records("phoenix_kit_sync_connections")
    end

    test "returns {:error, :table_not_found} for non-existent table" do
      assert {:error, :table_not_found} = DataExporter.fetch_records("nonexistent_table_xyz")
    end

    test "returns 1 record after inserting a connection" do
      _conn = create_test_connection()
      assert {:ok, records} = DataExporter.fetch_records("phoenix_kit_sync_connections")
      assert length(records) == 1
      assert is_map(hd(records))
    end
  end

  describe "fetch_records/2 with limit/offset options" do
    test "limit is respected" do
      _conn1 = create_test_connection()
      _conn2 = create_test_connection()
      _conn3 = create_test_connection()

      assert {:ok, records} = DataExporter.fetch_records("phoenix_kit_sync_connections", limit: 2)
      assert length(records) == 2
    end

    test "offset skips records" do
      _conn1 = create_test_connection()
      _conn2 = create_test_connection()
      _conn3 = create_test_connection()

      assert {:ok, all_records} = DataExporter.fetch_records("phoenix_kit_sync_connections")
      assert {:ok, offset_records} = DataExporter.fetch_records("phoenix_kit_sync_connections", offset: 1)
      assert length(offset_records) == length(all_records) - 1
    end
  end

  # ===========================================
  # stream_records/1
  # ===========================================

  describe "stream_records/1" do
    test "returns {:ok, stream} that can be enumerated on empty table" do
      assert {:ok, stream} = DataExporter.stream_records("phoenix_kit_sync_connections")
      records = stream |> Enum.to_list() |> List.flatten()
      assert records == []
    end

    test "returns {:ok, stream} with records after inserting data" do
      _conn = create_test_connection()
      assert {:ok, stream} = DataExporter.stream_records("phoenix_kit_sync_connections")
      records = stream |> Enum.to_list() |> List.flatten()
      assert length(records) == 1
    end

    test "returns error for non-existent table" do
      assert {:error, _reason} = DataExporter.stream_records("nonexistent_table_xyz")
    end
  end
end
