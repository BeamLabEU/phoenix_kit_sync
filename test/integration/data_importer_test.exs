defmodule PhoenixKitSync.Integration.DataImporterTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.Test.Repo

  @test_table "sync_test_import"

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@test_table} (
      id serial PRIMARY KEY,
      name varchar(255),
      email varchar(255),
      age integer,
      inserted_at timestamp DEFAULT now()
    )
    """)

    on_exit(fn ->
      Repo.query!("TRUNCATE #{@test_table}")
    end)

    :ok
  end

  defp count_rows do
    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM #{@test_table}")
    count
  end

  defp fetch_all_rows do
    %{rows: rows, columns: columns} = Repo.query!("SELECT * FROM #{@test_table}")
    Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
  end

  # ===========================================
  # :skip strategy
  # ===========================================

  describe "import_records/3 with :skip strategy" do
    test "inserts new records" do
      records = [
        %{"name" => "Alice", "email" => "alice@example.com", "age" => 30},
        %{"name" => "Bob", "email" => "bob@example.com", "age" => 25}
      ]

      assert {:ok, result} = DataImporter.import_records(@test_table, records, :skip)
      assert result.created == 2
      assert result.skipped == 0
      assert result.updated == 0
      assert result.errors == []
      assert count_rows() == 2
    end

    test "skips existing records with matching primary key" do
      # Insert initial record
      records = [%{"name" => "Alice", "email" => "alice@example.com", "age" => 30}]
      {:ok, _} = DataImporter.import_records(@test_table, records, :skip)

      # Get the inserted id
      [existing] = fetch_all_rows()
      id = existing["id"]

      # Try to import a record with the same primary key
      duplicate = [%{"id" => id, "name" => "Alice Updated", "email" => "new@example.com", "age" => 99}]
      assert {:ok, result} = DataImporter.import_records(@test_table, duplicate, :skip)
      assert result.skipped == 1
      assert result.created == 0

      # Original data should be unchanged
      [row] = fetch_all_rows()
      assert row["name"] == "Alice"
    end
  end

  # ===========================================
  # :overwrite strategy
  # ===========================================

  describe "import_records/3 with :overwrite strategy" do
    test "replaces existing records" do
      records = [%{"name" => "Alice", "email" => "alice@example.com", "age" => 30}]
      {:ok, _} = DataImporter.import_records(@test_table, records, :skip)

      [existing] = fetch_all_rows()
      id = existing["id"]

      overwrite_records = [%{"id" => id, "name" => "Alice Overwritten", "email" => "overwritten@example.com", "age" => 99}]
      assert {:ok, result} = DataImporter.import_records(@test_table, overwrite_records, :overwrite)
      assert result.updated == 1
      assert result.created == 0

      [row] = fetch_all_rows()
      assert row["name"] == "Alice Overwritten"
      assert row["email"] == "overwritten@example.com"
      assert row["age"] == 99
    end

    test "inserts new records when no conflict" do
      records = [%{"name" => "New Person", "email" => "new@example.com", "age" => 40}]
      assert {:ok, result} = DataImporter.import_records(@test_table, records, :overwrite)
      assert result.created == 1
      assert result.updated == 0
    end
  end

  # ===========================================
  # :merge strategy
  # ===========================================

  describe "import_records/3 with :merge strategy" do
    test "merges without overwriting existing non-nil values with nil" do
      records = [%{"name" => "Alice", "email" => "alice@example.com", "age" => 30}]
      {:ok, _} = DataImporter.import_records(@test_table, records, :skip)

      [existing] = fetch_all_rows()
      id = existing["id"]

      # Merge with nil email - should keep existing email
      merge_records = [%{"id" => id, "name" => "Alice Merged", "email" => nil, "age" => 35}]
      assert {:ok, result} = DataImporter.import_records(@test_table, merge_records, :merge)
      assert result.updated == 1

      [row] = fetch_all_rows()
      assert row["name"] == "Alice Merged"
      # email should remain from the existing record since the new value is nil
      assert row["email"] == "alice@example.com"
      assert row["age"] == 35
    end

    test "inserts new records when no existing record found" do
      records = [%{"name" => "New", "email" => "new@example.com", "age" => 20}]
      assert {:ok, result} = DataImporter.import_records(@test_table, records, :merge)
      assert result.created == 1
    end
  end

  # ===========================================
  # :append strategy
  # ===========================================

  describe "import_records/3 with :append strategy" do
    test "always inserts as new records, stripping primary key" do
      records = [%{"name" => "Alice", "email" => "alice@example.com", "age" => 30}]
      {:ok, _} = DataImporter.import_records(@test_table, records, :skip)

      [existing] = fetch_all_rows()
      id = existing["id"]

      # Append with the same id - should create a new record with a different id
      append_records = [%{"id" => id, "name" => "Alice Copy", "email" => "copy@example.com", "age" => 30}]
      assert {:ok, result} = DataImporter.import_records(@test_table, append_records, :append)
      assert result.created == 1

      all = fetch_all_rows()
      assert length(all) == 2
    end
  end

  # ===========================================
  # Result counts
  # ===========================================

  describe "result counts" do
    test "returns proper counts for mixed operations" do
      # Insert two initial records
      records = [
        %{"name" => "Alice", "email" => "alice@example.com", "age" => 30},
        %{"name" => "Bob", "email" => "bob@example.com", "age" => 25}
      ]

      {:ok, _} = DataImporter.import_records(@test_table, records, :skip)
      existing = fetch_all_rows()
      id1 = Enum.at(existing, 0)["id"]
      id2 = Enum.at(existing, 1)["id"]

      # Import: one existing (skip), one existing (skip), one new (create)
      mixed_records = [
        %{"id" => id1, "name" => "Alice Updated", "email" => "a@example.com", "age" => 31},
        %{"id" => id2, "name" => "Bob Updated", "email" => "b@example.com", "age" => 26},
        %{"name" => "Charlie", "email" => "charlie@example.com", "age" => 40}
      ]

      assert {:ok, result} = DataImporter.import_records(@test_table, mixed_records, :skip)
      assert result.created == 1
      assert result.skipped == 2
      assert result.errors == []
    end
  end

  # ===========================================
  # Error handling
  # ===========================================

  describe "error handling" do
    test "returns error for nonexistent table" do
      records = [%{"name" => "Test"}]
      assert {:error, _reason} = DataImporter.import_records("nonexistent_table_xyz", records, :skip)
    end
  end

  # ===========================================
  # import_multiple/2
  # ===========================================

  describe "import_multiple/2" do
    test "imports to multiple tables" do
      # Create a second test table
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS sync_test_import_extra (
        id serial PRIMARY KEY,
        label varchar(255)
      )
      """)

      on_exit(fn ->
        Repo.query!("TRUNCATE sync_test_import_extra")
      end)

      table_records = %{
        @test_table => [
          %{"name" => "Alice", "email" => "alice@example.com", "age" => 30}
        ],
        "sync_test_import_extra" => [
          %{"label" => "Tag A"},
          %{"label" => "Tag B"}
        ]
      }

      strategies = %{
        @test_table => :skip,
        "sync_test_import_extra" => :skip
      }

      assert {:ok, results} = DataImporter.import_multiple(table_records, strategies)
      assert is_map(results)
      assert results[@test_table].created == 1
      assert results["sync_test_import_extra"].created == 2
    end
  end
end
