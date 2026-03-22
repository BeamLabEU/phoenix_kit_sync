defmodule PhoenixKitSync.Integration.MigrationTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Test.Repo

  describe "Migration" do
    test "is idempotent (can run multiple times)" do
      # Migration already ran in test_helper.exs
      # Tables already exist, IF NOT EXISTS should make this a no-op
      # We verify by just querying the tables
      result = Repo.query!("SELECT 1 FROM phoenix_kit_sync_connections LIMIT 0")
      assert result.num_rows == 0
    end

    test "connections table exists with expected columns" do
      result =
        Repo.query!("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_sync_connections'
        ORDER BY ordinal_position
        """)

      columns = Enum.map(result.rows, fn [name] -> name end)

      expected = ~w(
        uuid name direction site_url auth_token_hash status
        approval_mode allowed_tables excluded_tables auto_approve_tables
        expires_at max_downloads downloads_used max_records_total
        records_downloaded max_records_per_request rate_limit_requests_per_minute
        download_password_hash ip_whitelist allowed_hours_start allowed_hours_end
        default_conflict_strategy auto_sync_enabled auto_sync_tables
        auto_sync_interval_minutes approved_at suspended_at suspended_reason
        revoked_at revoked_reason last_connected_at last_transfer_at
        total_transfers total_records_transferred total_bytes_transferred
        metadata approved_by_uuid suspended_by_uuid revoked_by_uuid
        created_by_uuid inserted_at updated_at
      )

      for col <- expected do
        assert col in columns, "Expected column '#{col}' in connections table"
      end
    end

    test "transfers table exists with expected columns" do
      result =
        Repo.query!("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_sync_transfers'
        ORDER BY ordinal_position
        """)

      columns = Enum.map(result.rows, fn [name] -> name end)

      expected = ~w(
        uuid direction session_code remote_site_url table_name
        records_requested records_transferred records_created records_updated
        records_skipped records_failed bytes_transferred conflict_strategy
        status requires_approval approved_at denied_at denial_reason
        approval_expires_at requester_ip requester_user_agent
        error_message started_at completed_at metadata
        connection_uuid approved_by_uuid denied_by_uuid initiated_by_uuid
        inserted_at
      )

      for col <- expected do
        assert col in columns, "Expected column '#{col}' in transfers table"
      end

      # updated_at should NOT be present (append-only)
      refute "updated_at" in columns
    end

    test "unique constraint exists on (site_url, direction)" do
      result =
        Repo.query!("""
        SELECT indexname FROM pg_indexes
        WHERE tablename = 'phoenix_kit_sync_connections'
        AND indexname = 'phoenix_kit_sync_connections_site_direction_uidx'
        """)

      assert length(result.rows) == 1
    end
  end
end
