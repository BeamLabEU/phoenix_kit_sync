defmodule PhoenixKitSync.ExcludedTablesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.SchemaInspector

  @never_synced [
    "schema_migrations",
    "oban_jobs",
    "oban_anything",
    "pg_class",
    "phoenix_kit_user_tokens",
    "phoenix_kit_users_tokens",
    # This module's own tables: auth_token_hash is the REST credential.
    "phoenix_kit_sync_connections",
    "phoenix_kit_sync_transfers",
    # Settings hold the incoming password and every integration's keys.
    "phoenix_kit_settings",
    "phoenix_kit_user_oauth_providers",
    "phoenix_kit_organization_invitations",
    "phoenix_kit_ai_accounts",
    "phoenix_kit_ai_endpoints",
    "phoenix_kit_buckets",
    "phoenix_kit_payment_provider_configs",
    # Not listed anywhere: excluded by what their names say they hold.
    "my_app_api_tokens",
    "shop_webhook_secrets",
    "partner_credentials",
    "Legacy_Passwords",
    "third_party_api_keys",
    "my_oauth_grants",
    "web_sessions"
  ]

  describe "SchemaInspector.excluded_table?/1" do
    test "excludes the table core actually uses for session tokens" do
      table = UserToken.__schema__(:source)
      assert table in @never_synced
      assert SchemaInspector.excluded_table?(table)
    end

    test "is true for the tables that are never synced" do
      for name <- @never_synced, do: assert(SchemaInspector.excluded_table?(name))
    end

    test "is false for other tables, phoenix_kit ones included" do
      for name <- ["users", "orders", "phoenix_kit_users", "phoenix_kit_posts"] do
        refute SchemaInspector.excluded_table?(name)
      end
    end
  end

  test "a connection cannot allow a never-synced table, even explicitly" do
    for name <- @never_synced do
      refute Connection.table_allowed?(%Connection{}, name)
      refute Connection.table_allowed?(%Connection{allowed_tables: [name]}, name)
    end
  end

  test "schema and export entry points refuse never-synced tables before querying" do
    for name <- @never_synced do
      assert {:error, :table_excluded} = SchemaInspector.get_schema(name)
      assert {:error, :table_excluded} = DataExporter.get_count(name)
      assert {:error, :table_excluded} = DataExporter.fetch_records(name)
      assert {:error, :table_excluded} = DataExporter.stream_records(name)
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
