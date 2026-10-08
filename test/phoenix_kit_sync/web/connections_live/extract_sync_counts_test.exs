defmodule PhoenixKitSync.Web.ConnectionsLive.ExtractSyncCountsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ConnectionsLive

  # Pinning tests for the per-error gettext-wrapped strings in
  # extract_sync_counts/1 (the C12 deep-dive fix). Each error variant
  # MUST return a translated string, not a raw English literal — these
  # tests would fail loudly if someone reverted the gettext wrappers.
  #
  # The function is `@doc false def` (testing-only entry point) so we
  # can pin the strings without driving the full sync flow.

  describe "happy paths" do
    test ":ok with imported/skipped/errors counts → {n, n, n, nil}" do
      assert {3, 1, 0, nil} =
               ConnectionsLive.extract_sync_counts({:ok, %{imported: 3, skipped: 1, errors: 0}})
    end

    test ":ok with only :imported count → {n, 0, 0, nil}" do
      assert {7, 0, 0, nil} = ConnectionsLive.extract_sync_counts({:ok, %{imported: 7}})
    end
  end

  describe "error paths — translated strings" do
    test ":offline returns a translated 'Sender is offline' message" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :offline})
      assert is_binary(msg)
      assert String.length(msg) > 0
      # Pin the English source so a regression that drops the gettext
      # wrap surfaces as a different fail mode (raw atom inspection).
      assert msg == "Sender is offline"
    end

    test ":unauthorized returns a translated message" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :unauthorized})
      assert is_binary(msg)
      assert msg == "Unauthorized - check connection token"
    end

    test ":table_not_found returns a translated message" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :table_not_found})
      assert is_binary(msg)
      assert msg == "Table not found on sender"
    end

    test ":no_primary_key says why the table was not imported" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :no_primary_key})
      assert msg =~ "Not pulled: the table has no primary key here"
    end

    test "invalid names from the sender say what was refused" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :invalid_column_name})
      assert msg == "The sender sent a column name that is not a valid identifier"

      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :invalid_table_name})
      assert msg == "Invalid table name"
    end

    test "unknown columns are named, alongside the counts" do
      assert {1, 0, 2, "Columns not in the local table: a, b"} =
               ConnectionsLive.extract_sync_counts(
                 {:ok, %{imported: 1, skipped: 0, errors: 2, unknown_columns: ["a", "b"]}}
               )
    end

    test "a truncated pull keeps its counts and says how to pull the rest" do
      assert {3, 1, 0, msg} =
               ConnectionsLive.extract_sync_counts(
                 {:ok, %{imported: 3, skipped: 1, errors: 0, truncated: true}}
               )

      assert msg =~ "max_records_per_request"
    end

    test ":table_missing_locally points at creating the table" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts({:error, :table_missing_locally})
      assert msg =~ "does not exist on this site"
    end

    test ":import_failed and :pull_failed point at the server log" do
      assert {0, 0, 0, "Importing this table failed; see the server log for details"} =
               ConnectionsLive.extract_sync_counts({:error, :import_failed})

      assert {0, 0, 0, "Pulling this table failed; see the server log for details"} =
               ConnectionsLive.extract_sync_counts({:error, :pull_failed})
    end

    test "binary error reason passes through untranslated" do
      # Free-text error strings from the importer (already partially
      # composed elsewhere) flow through verbatim — gettext can't
      # translate dynamic text. Documented behavior.
      {0, 0, 0, msg} =
        ConnectionsLive.extract_sync_counts({:error, "specific upstream error text"})

      assert msg == "specific upstream error text"
    end

    test "unknown error term gets gettext'd 'Sync failed: <reason>' with interpolation" do
      {0, 0, 0, msg} =
        ConnectionsLive.extract_sync_counts({:error, {:weird_unexpected, :error_shape}})

      assert is_binary(msg)
      assert msg =~ "Sync failed:"
      # The %{reason} placeholder is filled in via gettext/2 — the
      # inspected reason term is included in the translated string.
      assert msg =~ "weird_unexpected"
    end

    test "completely unrecognised result shape returns a translated 'Unknown error'" do
      {0, 0, 0, msg} = ConnectionsLive.extract_sync_counts(:totally_unexpected)
      assert is_binary(msg)
      assert msg == "Unknown error"
    end
  end
end
