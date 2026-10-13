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
  # tables without a primary key
  # ===========================================

  # No key means no order to page in, so such a table is served only when it
  # fits in one page: the page after it is empty, and a larger table is
  # refused before any of its rows are sent.
  describe "a table without a primary key" do
    setup do
      PhoenixKit.RepoHelper.repo().query!("CREATE TABLE de_keyless (label text)")

      PhoenixKit.RepoHelper.repo().query!(
        "INSERT INTO de_keyless SELECT 'r' || g FROM generate_series(1, 5) g"
      )

      :ok
    end

    test "is served whole when it fits in one page" do
      assert {:ok, records} = DataExporter.fetch_records("de_keyless", limit: 5)
      assert records |> Enum.map(& &1["label"]) |> Enum.sort() == ~w(r1 r2 r3 r4 r5)

      assert {:ok, %{records: [_ | _], next_after: nil}} =
               DataExporter.fetch_page("de_keyless", limit: 100)
    end

    test "has an empty page after the one page it fits in, so a paging reader ends" do
      assert {:ok, []} = DataExporter.fetch_records("de_keyless", limit: 5, offset: 5)
      assert {:ok, []} = DataExporter.fetch_records("de_keyless", limit: 5, offset: 1_000)
    end

    test "is refused when it has more rows than one page holds" do
      assert {:error, :no_primary_key} = DataExporter.fetch_records("de_keyless", limit: 4)
      assert {:error, :no_primary_key} = DataExporter.fetch_records("de_keyless", limit: 1)

      assert {:error, :no_primary_key} =
               DataExporter.fetch_records("de_keyless", limit: 2, offset: 2)
    end

    test "is refused at a position, which is a place in key order" do
      assert {:error, :no_primary_key} =
               DataExporter.fetch_page("de_keyless", after: %{"label" => "r1"})
    end

    test "an empty one is served as an empty page" do
      PhoenixKit.RepoHelper.repo().query!("DELETE FROM de_keyless")
      assert {:ok, []} = DataExporter.fetch_records("de_keyless", limit: 1)
    end

    test "streams whole when it fits in one batch and not at all when it does not" do
      assert {:ok, stream} = DataExporter.stream_records("de_keyless", batch_size: 5)
      assert stream |> Enum.to_list() |> List.flatten() |> length() == 5

      assert {:ok, stream} = DataExporter.stream_records("de_keyless", batch_size: 4)
      assert Enum.to_list(stream) == []
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
