defmodule PhoenixKitSync.Migration do
  @moduledoc """
  Creates the sync tables if they don't already exist.

  PhoenixKit's core migration system (V37, V44, V56, V58, V74) normally manages
  these tables. This module provides a fallback for installations where the tables
  haven't been created yet — every operation uses IF NOT EXISTS so it's safe to
  run even when tables already exist.

  ## Usage

      # In a migration file:
      def up do
        PhoenixKitSync.Migration.up()
      end

      # Or with a schema prefix:
      def up do
        PhoenixKitSync.Migration.up(prefix: "my_schema")
      end

  ## Tables Created

  - `phoenix_kit_sync_connections` — permanent token-based connections
  - `phoenix_kit_sync_transfers` — transfer history and approval workflow
  """

  use Ecto.Migration

  @connections_table "phoenix_kit_sync_connections"
  @transfers_table "phoenix_kit_sync_transfers"
  @users_table "phoenix_kit_users"

  @doc """
  Creates sync tables and indexes if they don't already exist.

  Options:
  - `:prefix` — schema prefix (default: `nil` for public schema)
  """
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix)

    create_connections_table(prefix)
    create_transfers_table(prefix)
  end

  @doc """
  Drops sync tables if they exist.
  """
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix)

    # Drop transfers first (has FK to connections)
    drop_fk_if_exists(@transfers_table, "connection_uuid", prefix)
    drop_fk_if_exists(@transfers_table, "approved_by_uuid", prefix)
    drop_fk_if_exists(@transfers_table, "denied_by_uuid", prefix)
    drop_fk_if_exists(@transfers_table, "initiated_by_uuid", prefix)
    drop_if_exists(table(@transfers_table, prefix: prefix))

    drop_fk_if_exists(@connections_table, "approved_by_uuid", prefix)
    drop_fk_if_exists(@connections_table, "suspended_by_uuid", prefix)
    drop_fk_if_exists(@connections_table, "revoked_by_uuid", prefix)
    drop_fk_if_exists(@connections_table, "created_by_uuid", prefix)
    drop_if_exists(table(@connections_table, prefix: prefix))
  end

  # ── Connections ──────────────────────────────────────────────────────

  defp create_connections_table(prefix) do
    create_if_not_exists table(@connections_table, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false)
      add(:direction, :string, size: 10, null: false)
      add(:site_url, :string, null: false)
      add(:auth_token, :string)
      add(:auth_token_hash, :string)
      add(:status, :string, size: 20, null: false, default: "pending")

      # Sender-side settings
      add(:approval_mode, :string, size: 20, default: "require_approval")
      add(:allowed_tables, {:array, :string}, null: false, default: [])
      add(:excluded_tables, {:array, :string}, null: false, default: [])
      add(:auto_approve_tables, {:array, :string}, null: false, default: [])

      # Expiration & limits
      add(:expires_at, :utc_datetime_usec)
      add(:max_downloads, :integer)
      add(:downloads_used, :integer, null: false, default: 0)
      add(:max_records_total, :bigint)
      add(:records_downloaded, :bigint, null: false, default: 0)

      # Per-request limits
      add(:max_records_per_request, :integer, null: false, default: 10_000)
      add(:rate_limit_requests_per_minute, :integer, null: false, default: 60)

      # Additional security
      add(:download_password_hash, :string)
      add(:ip_whitelist, {:array, :string}, null: false, default: [])
      add(:allowed_hours_start, :integer)
      add(:allowed_hours_end, :integer)

      # Receiver-side settings
      add(:default_conflict_strategy, :string, size: 20, default: "skip")
      add(:auto_sync_enabled, :boolean, null: false, default: false)
      add(:auto_sync_tables, {:array, :string}, null: false, default: [])
      add(:auto_sync_interval_minutes, :integer, null: false, default: 60)

      # Approval & status tracking
      add(:approved_at, :utc_datetime_usec)
      add(:suspended_at, :utc_datetime_usec)
      add(:suspended_reason, :string)
      add(:revoked_at, :utc_datetime_usec)
      add(:revoked_reason, :string)

      # Audit & statistics
      add(:last_connected_at, :utc_datetime_usec)
      add(:last_transfer_at, :utc_datetime_usec)
      add(:total_transfers, :integer, null: false, default: 0)
      add(:total_records_transferred, :bigint, null: false, default: 0)
      add(:total_bytes_transferred, :bigint, null: false, default: 0)

      add(:metadata, :map, null: false, default: %{})

      # UUID foreign keys to users
      add(:approved_by_uuid, :uuid)
      add(:suspended_by_uuid, :uuid)
      add(:revoked_by_uuid, :uuid)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(@connections_table, [:site_url, :direction],
        name: :phoenix_kit_sync_connections_site_direction_uidx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@connections_table, [:status],
        name: :phoenix_kit_sync_connections_status_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@connections_table, [:direction],
        name: :phoenix_kit_sync_connections_direction_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@connections_table, [:expires_at],
        name: :phoenix_kit_sync_connections_expires_at_idx,
        prefix: prefix
      )
    )

    # Foreign keys to users (if users table exists)
    add_user_fk_if_exists(@connections_table, "approved_by_uuid", prefix)
    add_user_fk_if_exists(@connections_table, "suspended_by_uuid", prefix)
    add_user_fk_if_exists(@connections_table, "revoked_by_uuid", prefix)
    add_user_fk_if_exists(@connections_table, "created_by_uuid", prefix)
  end

  # ── Transfers ────────────────────────────────────────────────────────

  defp create_transfers_table(prefix) do
    create_if_not_exists table(@transfers_table, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
      add(:direction, :string, size: 10, null: false)
      add(:session_code, :string, size: 20)
      add(:remote_site_url, :string)
      add(:table_name, :string, null: false)
      add(:records_requested, :integer, null: false, default: 0)
      add(:records_transferred, :integer, null: false, default: 0)
      add(:records_created, :integer, null: false, default: 0)
      add(:records_updated, :integer, null: false, default: 0)
      add(:records_skipped, :integer, null: false, default: 0)
      add(:records_failed, :integer, null: false, default: 0)
      add(:bytes_transferred, :bigint, null: false, default: 0)
      add(:conflict_strategy, :string, size: 20)

      # Status and approval
      add(:status, :string, size: 20, null: false, default: "pending")
      add(:requires_approval, :boolean, null: false, default: false)
      add(:approved_at, :utc_datetime_usec)
      add(:denied_at, :utc_datetime_usec)
      add(:denial_reason, :string)
      add(:approval_expires_at, :utc_datetime_usec)

      # Request context
      add(:requester_ip, :string)
      add(:requester_user_agent, :string)

      add(:error_message, :text)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})

      # UUID foreign keys
      add(:connection_uuid, :uuid)
      add(:approved_by_uuid, :uuid)
      add(:denied_by_uuid, :uuid)
      add(:initiated_by_uuid, :uuid)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create_if_not_exists(
      index(@transfers_table, [:direction],
        name: :phoenix_kit_sync_transfers_direction_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@transfers_table, [:connection_uuid],
        name: :phoenix_kit_sync_transfers_connection_uuid_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@transfers_table, [:status],
        name: :phoenix_kit_sync_transfers_status_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@transfers_table, [:initiated_by_uuid],
        name: :phoenix_kit_sync_transfers_initiated_by_uuid_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@transfers_table, [:inserted_at],
        name: :phoenix_kit_sync_transfers_inserted_at_idx,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(@transfers_table, [:requires_approval, :status],
        name: :phoenix_kit_sync_transfers_approval_idx,
        prefix: prefix
      )
    )

    # FK to connections table
    add_fk_if_not_exists(
      @transfers_table,
      "connection_uuid",
      @connections_table,
      "uuid",
      prefix
    )

    # FKs to users table (if it exists)
    add_user_fk_if_exists(@transfers_table, "approved_by_uuid", prefix)
    add_user_fk_if_exists(@transfers_table, "denied_by_uuid", prefix)
    add_user_fk_if_exists(@transfers_table, "initiated_by_uuid", prefix)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp prefix_name(table, nil), do: table
  defp prefix_name(table, prefix), do: "#{prefix}.#{table}"

  defp add_user_fk_if_exists(table, column, prefix) do
    add_fk_if_not_exists(table, column, @users_table, "uuid", prefix)
  end

  defp add_fk_if_not_exists(table, column, ref_table, ref_column, prefix) do
    constraint = "#{table}_#{column}_fkey"
    qualified_table = prefix_name(table, prefix)
    qualified_ref = prefix_name(ref_table, prefix)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = '#{ref_table}'
        #{if prefix, do: "AND table_schema = '#{prefix}'", else: "AND table_schema = 'public'"}
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{constraint}'
      ) THEN
        ALTER TABLE #{qualified_table}
        ADD CONSTRAINT #{constraint}
        FOREIGN KEY (#{column})
        REFERENCES #{qualified_ref}(#{ref_column})
        ON DELETE SET NULL;
      END IF;
    END $$;
    """)
  end

  defp drop_fk_if_exists(table, column, prefix) do
    constraint = "#{table}_#{column}_fkey"
    qualified_table = prefix_name(table, prefix)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = '#{constraint}'
      ) THEN
        ALTER TABLE #{qualified_table} DROP CONSTRAINT #{constraint};
      END IF;
    END $$;
    """)
  end
end
