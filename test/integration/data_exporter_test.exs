defmodule PhoenixKitSync.Integration.DataExporterTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.SyncableTable

  # ===========================================
  # get_count/1
  # ===========================================

  describe "get_count/1" do
    test "returns {:ok, 0} for an empty table" do
      assert {:ok, 0} = DataExporter.get_count(SyncableTable.name())
    end

    test "returns {:error, :table_not_found} for non-existent table" do
      assert {:error, :table_not_found} = DataExporter.get_count("nonexistent_table_xyz")
    end

    test "returns {:ok, 1} after inserting a row" do
      _conn = SyncableTable.insert!()
      assert {:ok, 1} = DataExporter.get_count(SyncableTable.name())
    end
  end

  # ===========================================
  # fetch_records/1
  # ===========================================

  describe "fetch_records/1" do
    test "returns {:ok, []} for empty table" do
      assert {:ok, []} = DataExporter.fetch_records(SyncableTable.name())
    end

    test "returns {:error, :table_not_found} for non-existent table" do
      assert {:error, :table_not_found} = DataExporter.fetch_records("nonexistent_table_xyz")
    end

    test "returns 1 record after inserting a row" do
      _conn = SyncableTable.insert!()
      assert {:ok, records} = DataExporter.fetch_records(SyncableTable.name())
      assert length(records) == 1
      assert is_map(hd(records))
    end
  end

  describe "fetch_records/2 with limit/offset options" do
    test "limit is respected" do
      _conn1 = SyncableTable.insert!()
      _conn2 = SyncableTable.insert!()
      _conn3 = SyncableTable.insert!()

      assert {:ok, records} = DataExporter.fetch_records(SyncableTable.name(), limit: 2)
      assert length(records) == 2
    end

    test "offset skips records" do
      _conn1 = SyncableTable.insert!()
      _conn2 = SyncableTable.insert!()
      _conn3 = SyncableTable.insert!()

      assert {:ok, all_records} = DataExporter.fetch_records(SyncableTable.name())

      assert {:ok, offset_records} =
               DataExporter.fetch_records(SyncableTable.name(), offset: 1)

      assert length(offset_records) == length(all_records) - 1
    end
  end

  # ===========================================
  # stream_records/1
  # ===========================================

  describe "stream_records/1" do
    test "returns {:ok, stream} that can be enumerated on empty table" do
      assert {:ok, stream} = DataExporter.stream_records(SyncableTable.name())
      records = stream |> Enum.to_list() |> List.flatten()
      assert records == []
    end

    test "returns {:ok, stream} with records after inserting data" do
      _conn = SyncableTable.insert!()
      assert {:ok, stream} = DataExporter.stream_records(SyncableTable.name())
      records = stream |> Enum.to_list() |> List.flatten()
      assert length(records) == 1
    end

    test "returns error for non-existent table" do
      assert {:error, _reason} = DataExporter.stream_records("nonexistent_table_xyz")
    end
  end
end
