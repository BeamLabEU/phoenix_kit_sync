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

  test "refuses a table that is never synced, before touching it" do
    for table <- ["phoenix_kit_user_tokens", "schema_migrations", "oban_jobs"] do
      assert {:error, :table_excluded} = DataImporter.import_records(table, [%{}], :overwrite)
    end
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
      duplicate = [
        %{"id" => id, "name" => "Alice Updated", "email" => "new@example.com", "age" => 99}
      ]

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

      overwrite_records = [
        %{
          "id" => id,
          "name" => "Alice Overwritten",
          "email" => "overwritten@example.com",
          "age" => 99
        }
      ]

      assert {:ok, result} =
               DataImporter.import_records(@test_table, overwrite_records, :overwrite)

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
      append_records = [
        %{"id" => id, "name" => "Alice Copy", "email" => "copy@example.com", "age" => 30}
      ]

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

      assert {:error, _reason} =
               DataImporter.import_records("nonexistent_table_xyz", records, :skip)
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

  describe "batched find_existing (N+1 fix)" do
    # Regression pin for the pre-fetch optimisation. Before this change,
    # a batch of N records with a :skip strategy ran N SELECTs before any
    # INSERT. The pre-fetch collapses those into one SELECT …
    # WHERE "pk" = ANY($1). Correctness-wise, the observable behavior is
    # identical — this test asserts that identical observable behavior on
    # a mixed batch of new + existing records.
    test "correctly splits a mixed batch into created + skipped" do
      # Seed three rows. Their ids are serial; fetch them back.
      seed = [
        %{"name" => "Existing 1", "email" => "e1@x.io", "age" => 10},
        %{"name" => "Existing 2", "email" => "e2@x.io", "age" => 20},
        %{"name" => "Existing 3", "email" => "e3@x.io", "age" => 30}
      ]

      assert {:ok, %{created: 3}} = DataImporter.import_records(@test_table, seed, :skip)
      assert count_rows() == 3

      [r1, r2, r3] = fetch_all_rows()

      # Mixed batch: three records that collide with existing PKs (should
      # skip) plus two with fresh PKs (should insert). The pre-fetch path
      # resolves all five lookups in one query.
      batch = [
        %{"id" => r1["id"], "name" => "Updated 1", "email" => "u1@x.io", "age" => 11},
        %{"id" => r2["id"], "name" => "Updated 2", "email" => "u2@x.io", "age" => 22},
        %{"id" => r3["id"], "name" => "Updated 3", "email" => "u3@x.io", "age" => 33},
        %{"name" => "New A", "email" => "new-a@x.io", "age" => 40},
        %{"name" => "New B", "email" => "new-b@x.io", "age" => 50}
      ]

      assert {:ok, result} = DataImporter.import_records(@test_table, batch, :skip)
      assert result.created == 2
      assert result.skipped == 3
      assert result.updated == 0
      assert result.errors == []
      assert count_rows() == 5

      # Existing rows untouched — the :skip strategy preserved them.
      names = fetch_all_rows() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["Existing 1", "Existing 2", "Existing 3", "New A", "New B"]
    end

    test "overwrite strategy correctly updates all matched records in batch" do
      # Seed + update all three via :overwrite. Pre-fetch resolves all
      # three lookups in one query; per-record UPDATE still happens.
      seed = [
        %{"name" => "Before 1", "email" => "b1@x.io", "age" => 1},
        %{"name" => "Before 2", "email" => "b2@x.io", "age" => 2}
      ]

      assert {:ok, %{created: 2}} = DataImporter.import_records(@test_table, seed, :skip)
      [r1, r2] = fetch_all_rows()

      batch = [
        %{"id" => r1["id"], "name" => "After 1", "email" => "a1@x.io", "age" => 100},
        %{"id" => r2["id"], "name" => "After 2", "email" => "a2@x.io", "age" => 200}
      ]

      assert {:ok, result} = DataImporter.import_records(@test_table, batch, :overwrite)
      assert result.updated == 2
      assert result.created == 0
      assert count_rows() == 2

      names = fetch_all_rows() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["After 1", "After 2"]
    end

    test ":append strategy skips the pre-fetch entirely (no PK conflict check)" do
      # Append should create new rows regardless of existing PKs. The
      # prefetch_existing guard returns an empty map for :append.
      seed = [%{"name" => "Seed", "email" => "seed@x.io", "age" => 1}]
      assert {:ok, %{created: 1}} = DataImporter.import_records(@test_table, seed, :skip)
      [r1] = fetch_all_rows()

      # A record whose explicit id collides with the seed — :append strips
      # the PK before insert, so the DB assigns a fresh serial id.
      batch = [
        %{"id" => r1["id"], "name" => "Appended", "email" => "app@x.io", "age" => 99}
      ]

      assert {:ok, %{created: 1}} = DataImporter.import_records(@test_table, batch, :append)
      assert count_rows() == 2

      names = fetch_all_rows() |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["Appended", "Seed"]
    end
  end

  describe "identifier validation (SQL injection guard)" do
    test "rejects table names with SQL metacharacters" do
      records = [%{"name" => "Alice", "email" => "a@x.io", "age" => 1}]

      # Baseline: a known-good table inserts cleanly.
      assert {:ok, %{created: 1}} = DataImporter.import_records(@test_table, records, :skip)

      # Classic injection payloads — semicolon-drop, quote-break, comment,
      # tautology. Every one must be rejected before any SQL is executed
      # against the target table. Rejection surfaces as a plain `{:error, _}`
      # from SchemaInspector.get_schema/1, which runs *before* DataImporter's
      # internal SQL builder sees the identifier. That's defense in depth:
      # even if a caller bypassed get_schema, DataImporter's own
      # valid_identifier? guard would refuse the query.
      for bad_table <- [
            "#{@test_table}; DROP TABLE #{@test_table}; --",
            "#{@test_table}'--",
            "#{@test_table} OR 1=1",
            "#{@test_table}\"; DELETE FROM #{@test_table}; --"
          ] do
        assert {:error, _reason} = DataImporter.import_records(bad_table, records, :skip)
      end

      # The original row survived every attempted injection.
      assert count_rows() == 1
    end

    test "rejects column names with SQL metacharacters" do
      # A record with a weaponised column name — note that SchemaInspector's
      # get_schema only validates the table, so this payload *does* reach
      # DataImporter's internal SQL path. The column-level identifier check
      # stops the insert there: nothing lands in the DB, and the error is
      # accumulated per-record rather than crashing the whole batch.
      bad_record = [%{"name\"; DROP TABLE x; --" => "hacked"}]

      assert {:ok, result} = DataImporter.import_records(@test_table, bad_record, :skip)
      assert result.created == 0
      assert result.errors != []
      assert count_rows() == 0
    end
  end
end
