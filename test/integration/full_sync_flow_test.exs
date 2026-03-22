defmodule PhoenixKitSync.Integration.FullSyncFlowTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.Repo
  alias PhoenixKitSync.Transfers

  describe "complete sync workflow" do
    setup do
      # Create a test table with some data to sync
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS sync_flow_test (
        id serial PRIMARY KEY,
        name varchar(255) NOT NULL,
        email varchar(255),
        active boolean DEFAULT true,
        inserted_at timestamp DEFAULT now()
      )
      """)

      Repo.query!("TRUNCATE sync_flow_test")

      # Insert test data
      Repo.query!("""
      INSERT INTO sync_flow_test (name, email, active) VALUES
        ('Alice', 'alice@example.com', true),
        ('Bob', 'bob@example.com', true),
        ('Charlie', 'charlie@example.com', false)
      """)

      on_exit(fn ->
        try do
          Repo.query!("DROP TABLE IF EXISTS sync_flow_test")
        rescue
          _ -> :ok
        end
      end)

      :ok
    end

    test "export records from source table" do
      assert {:ok, count} = DataExporter.get_count("sync_flow_test")
      assert count == 3

      assert {:ok, records} = DataExporter.fetch_records("sync_flow_test")
      assert length(records) == 3

      names = Enum.map(records, & &1["name"])
      assert "Alice" in names
      assert "Bob" in names
      assert "Charlie" in names
    end

    test "inspect schema of source table" do
      assert {:ok, schema} = SchemaInspector.get_schema("sync_flow_test")
      assert schema.table == "sync_flow_test"

      column_names = Enum.map(schema.columns, & &1.name)
      assert "id" in column_names
      assert "name" in column_names
      assert "email" in column_names
      assert "active" in column_names
    end

    test "full export -> import cycle with skip strategy" do
      # Export from source
      {:ok, records} = DataExporter.fetch_records("sync_flow_test")

      # Create destination table
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS sync_flow_dest (
        id serial PRIMARY KEY,
        name varchar(255),
        email varchar(255),
        active boolean DEFAULT true,
        inserted_at timestamp DEFAULT now()
      )
      """)

      Repo.query!("TRUNCATE sync_flow_dest")

      # Import with skip strategy
      {:ok, result} = DataImporter.import_records("sync_flow_dest", records, :skip)
      assert result.created == 3
      assert result.skipped == 0

      # Import again - should skip all
      {:ok, result2} = DataImporter.import_records("sync_flow_dest", records, :skip)
      assert result2.skipped == 3
      assert result2.created == 0

      # Cleanup
      try do
        Repo.query!("DROP TABLE IF EXISTS sync_flow_dest")
      rescue
        _ -> :ok
      end
    end

    test "full export -> import cycle with append strategy" do
      {:ok, records} = DataExporter.fetch_records("sync_flow_test")

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS sync_flow_append (
        id serial PRIMARY KEY,
        name varchar(255),
        email varchar(255),
        active boolean DEFAULT true,
        inserted_at timestamp DEFAULT now()
      )
      """)

      Repo.query!("TRUNCATE sync_flow_append")

      # Import with append (always creates new records)
      {:ok, result} = DataImporter.import_records("sync_flow_append", records, :append)
      assert result.created == 3

      # Import again with append - creates duplicates
      {:ok, result2} = DataImporter.import_records("sync_flow_append", records, :append)
      assert result2.created == 3

      # Should have 6 total
      {:ok, count} = DataExporter.get_count("sync_flow_append")
      assert count == 6

      try do
        Repo.query!("DROP TABLE IF EXISTS sync_flow_append")
      rescue
        _ -> :ok
      end
    end

    test "connection + transfer tracking for a sync operation" do
      # Create a connection
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Flow Test Connection",
          "direction" => "sender",
          "site_url" => "https://flow-test-#{System.unique_integer([:positive])}.com",
          "approval_mode" => "auto_approve"
        })

      {:ok, active_conn} = Connections.approve_connection(conn, UUIDv7.generate())

      # Create a transfer record
      {:ok, transfer} =
        Transfers.create_transfer(%{
          direction: "send",
          table_name: "sync_flow_test",
          connection_uuid: active_conn.uuid,
          records_requested: 3,
          conflict_strategy: "skip"
        })

      assert transfer.status == "pending"

      # Start the transfer
      {:ok, started} = Transfers.start_transfer(transfer)
      assert started.status == "in_progress"
      assert started.started_at != nil

      # Export the data
      {:ok, records} = DataExporter.fetch_records("sync_flow_test")
      assert length(records) == 3

      # Complete the transfer with stats
      {:ok, completed} =
        Transfers.complete_transfer(started, %{
          records_transferred: 3,
          records_created: 3,
          bytes_transferred: 1500
        })

      assert completed.status == "completed"
      assert completed.records_transferred == 3
      assert completed.records_created == 3
      assert completed.completed_at != nil

      # Verify stats
      stats = Transfers.connection_stats(active_conn.uuid)
      assert is_map(stats)
      assert stats.total_transfers >= 1
    end

    test "table checksum detects changes" do
      {:ok, checksum1} = SchemaInspector.get_table_checksum("sync_flow_test")
      assert is_binary(checksum1)
      refute checksum1 == "empty"

      # Insert more data
      Repo.query!("INSERT INTO sync_flow_test (name, email) VALUES ('Dave', 'dave@example.com')")

      {:ok, checksum2} = SchemaInspector.get_table_checksum("sync_flow_test")
      assert is_binary(checksum2)

      # Checksums should differ
      assert checksum1 != checksum2
    end

    test "schema inspector can list foreign keys" do
      {:ok, fk_map} = SchemaInspector.get_all_foreign_keys()
      assert is_map(fk_map)

      # Our sync tables have FKs (transfers -> connections)
      if Map.has_key?(fk_map, "phoenix_kit_sync_transfers") do
        assert "phoenix_kit_sync_connections" in fk_map["phoenix_kit_sync_transfers"]
      end
    end

    test "data export with pagination" do
      # Fetch with limit
      {:ok, page1} = DataExporter.fetch_records("sync_flow_test", limit: 2, offset: 0)
      assert length(page1) == 2

      {:ok, page2} = DataExporter.fetch_records("sync_flow_test", limit: 2, offset: 2)
      assert length(page2) == 1

      # All records accounted for
      all_names = Enum.map(page1 ++ page2, & &1["name"])
      assert length(all_names) == 3
    end

    test "stream export processes all records" do
      {:ok, stream} = DataExporter.stream_records("sync_flow_test", batch_size: 2)
      all_records = stream |> Enum.to_list() |> List.flatten()
      assert length(all_records) == 3
    end

    test "transfer fail and cancel workflows" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Fail Test Connection",
          "direction" => "sender",
          "site_url" => "https://fail-test-#{System.unique_integer([:positive])}.com"
        })

      {:ok, active_conn} = Connections.approve_connection(conn, UUIDv7.generate())

      # Test fail workflow
      {:ok, transfer} =
        Transfers.create_transfer(%{
          direction: "send",
          table_name: "sync_flow_test",
          connection_uuid: active_conn.uuid,
          records_requested: 3
        })

      {:ok, started} = Transfers.start_transfer(transfer)
      {:ok, failed} = Transfers.fail_transfer(started, "Connection timeout")
      assert failed.status == "failed"
      assert failed.error_message == "Connection timeout"
      assert failed.completed_at != nil

      # Test cancel workflow
      {:ok, transfer2} =
        Transfers.create_transfer(%{
          direction: "send",
          table_name: "sync_flow_test",
          connection_uuid: active_conn.uuid,
          records_requested: 3
        })

      {:ok, started2} = Transfers.start_transfer(transfer2)
      {:ok, cancelled} = Transfers.cancel_transfer(started2)
      assert cancelled.status == "cancelled"
      assert cancelled.completed_at != nil
    end

    test "transfer approval workflow" do
      {:ok, conn, _token} =
        Connections.create_connection(%{
          "name" => "Approval Test",
          "direction" => "sender",
          "site_url" => "https://approval-test-#{System.unique_integer([:positive])}.com"
        })

      {:ok, active_conn} = Connections.approve_connection(conn, UUIDv7.generate())

      {:ok, transfer} =
        Transfers.create_transfer(%{
          direction: "send",
          table_name: "sync_flow_test",
          connection_uuid: active_conn.uuid,
          records_requested: 3,
          requires_approval: true
        })

      # Request approval
      {:ok, pending} = Transfers.request_approval(transfer)
      assert pending.status == "pending_approval"
      assert pending.approval_expires_at != nil

      # Approve it
      admin_uuid = UUIDv7.generate()
      {:ok, approved} = Transfers.approve_transfer(pending, admin_uuid)
      assert approved.status == "approved"
      assert approved.approved_at != nil

      # Now it can be started
      {:ok, started} = Transfers.start_transfer(approved)
      assert started.status == "in_progress"
    end

    test "schema inspector get_primary_key" do
      {:ok, pks} = SchemaInspector.get_primary_key("sync_flow_test")
      assert pks == ["id"]
    end

    test "schema inspector table_exists?" do
      assert SchemaInspector.table_exists?("sync_flow_test")
      refute SchemaInspector.table_exists?("nonexistent_table_xyz")
    end

    test "data exporter returns error for nonexistent table" do
      assert {:error, :table_not_found} = DataExporter.get_count("nonexistent_table_xyz")
      assert {:error, :table_not_found} = DataExporter.fetch_records("nonexistent_table_xyz")
    end
  end
end
