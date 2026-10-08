defmodule PhoenixKitSync.ExcludedTablesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.SchemaInspector

  @never_synced [
    "schema_migrations",
    "oban_jobs",
    "oban_anything",
    "pg_class",
    "phoenix_kit_user_tokens"
  ]

  describe "SchemaInspector.excluded_table?/1" do
    test "is true for the tables that are never synced" do
      for name <- @never_synced, do: assert(SchemaInspector.excluded_table?(name))
    end

    test "is false for other tables, phoenix_kit ones included" do
      for name <- ["users", "orders", "phoenix_kit_users", "phoenix_kit_sync_connections"] do
        refute SchemaInspector.excluded_table?(name)
      end
    end
  end

  # The table name comes from the sender's list, so the pull refuses it
  # before it looks at the connection, the sender or the local database.
  describe "a pull of a table that is never synced" do
    test "pull_table_data/3 refuses it" do
      for name <- @never_synced do
        assert {:error, :table_excluded} = ConnectionNotifier.pull_table_data(%{}, name)
      end
    end

    test "pull_table_data_with_remap/4 refuses it and hands the remap back" do
      remap = %{"users" => %{}}

      assert {:error, :table_excluded, ^remap} =
               ConnectionNotifier.pull_table_data_with_remap(%{}, "schema_migrations", remap)
    end
  end
end
