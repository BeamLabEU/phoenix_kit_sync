# PhoenixKitSync Database Tables

These tables are normally created by PhoenixKit's core migration system
(V37, V44, V56, V58, V74). If they don't already exist, you can create them
with `PhoenixKitSync.Migration.up/0` — all operations use IF NOT EXISTS.

## phoenix_kit_sync_connections

Permanent, token-based connections between PhoenixKit sites.

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| uuid | uuid | NO | uuid_generate_v7() | Primary key (UUIDv7) |
| name | varchar | NO | | Connection display name |
| direction | varchar(10) | NO | | "sender" or "receiver" |
| site_url | varchar | NO | | Remote site URL |
| auth_token | varchar | YES | | Plaintext token (cleared after creation) |
| auth_token_hash | varchar | YES | | SHA256 hash of auth token |
| status | varchar(20) | NO | "pending" | pending/active/suspended/revoked/expired |
| approval_mode | varchar(20) | YES | "require_approval" | auto_approve/require_approval/per_table |
| allowed_tables | text[] | NO | {} | Whitelist (empty = all) |
| excluded_tables | text[] | NO | {} | Blacklist |
| auto_approve_tables | text[] | NO | {} | Tables that skip approval |
| expires_at | timestamptz | YES | | Expiration timestamp |
| max_downloads | integer | YES | | Download operation limit |
| downloads_used | integer | NO | 0 | Counter |
| max_records_total | bigint | YES | | Total record limit |
| records_downloaded | bigint | NO | 0 | Counter |
| max_records_per_request | integer | NO | 10000 | Per-request limit |
| rate_limit_requests_per_minute | integer | NO | 60 | Rate limit |
| download_password_hash | varchar | YES | | SHA256 hash |
| ip_whitelist | text[] | NO | {} | Allowed IPs |
| allowed_hours_start | integer | YES | | 0-23 |
| allowed_hours_end | integer | YES | | 0-23 |
| default_conflict_strategy | varchar(20) | YES | "skip" | skip/overwrite/merge/append |
| auto_sync_enabled | boolean | NO | false | |
| auto_sync_tables | text[] | NO | {} | |
| auto_sync_interval_minutes | integer | NO | 60 | |
| approved_at | timestamptz | YES | | |
| suspended_at | timestamptz | YES | | |
| suspended_reason | varchar | YES | | |
| revoked_at | timestamptz | YES | | |
| revoked_reason | varchar | YES | | |
| last_connected_at | timestamptz | YES | | |
| last_transfer_at | timestamptz | YES | | |
| total_transfers | integer | NO | 0 | |
| total_records_transferred | bigint | NO | 0 | |
| total_bytes_transferred | bigint | NO | 0 | |
| metadata | jsonb | NO | {} | |
| approved_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| suspended_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| revoked_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| created_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| inserted_at | timestamptz | NO | | |
| updated_at | timestamptz | NO | | |

**Unique constraint:** `(site_url, direction)` — `phoenix_kit_sync_connections_site_direction_uidx`

**Indexes:** status, direction, expires_at

## phoenix_kit_sync_transfers

Transfer history with approval workflow.

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| uuid | uuid | NO | uuid_generate_v7() | Primary key (UUIDv7) |
| direction | varchar(10) | NO | | "send" or "receive" |
| session_code | varchar(20) | YES | | 8-char ephemeral code |
| remote_site_url | varchar | YES | | |
| table_name | varchar | NO | | Target table |
| records_requested | integer | NO | 0 | |
| records_transferred | integer | NO | 0 | |
| records_created | integer | NO | 0 | |
| records_updated | integer | NO | 0 | |
| records_skipped | integer | NO | 0 | |
| records_failed | integer | NO | 0 | |
| bytes_transferred | bigint | NO | 0 | |
| conflict_strategy | varchar(20) | YES | | skip/overwrite/merge/append |
| status | varchar(20) | NO | "pending" | pending/pending_approval/approved/denied/in_progress/completed/failed/cancelled/expired |
| requires_approval | boolean | NO | false | |
| approved_at | timestamptz | YES | | |
| denied_at | timestamptz | YES | | |
| denial_reason | varchar | YES | | |
| approval_expires_at | timestamptz | YES | | |
| requester_ip | varchar | YES | | |
| requester_user_agent | varchar | YES | | |
| error_message | text | YES | | |
| started_at | timestamptz | YES | | |
| completed_at | timestamptz | YES | | |
| metadata | jsonb | NO | {} | |
| connection_uuid | uuid | YES | | FK to phoenix_kit_sync_connections |
| approved_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| denied_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| initiated_by_uuid | uuid | YES | | FK to phoenix_kit_users |
| inserted_at | timestamptz | NO | | |

**Note:** `updated_at` is NOT present — transfers are append-only with status transitions.

**Indexes:** direction, connection_uuid, status, initiated_by_uuid, inserted_at, (requires_approval + status)

## Settings Keys

Stored in `phoenix_kit_settings` table:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `sync_enabled` | boolean | false | Module enable/disable |
| `sync_incoming_mode` | string | "require_approval" | auto_accept/require_approval/require_password/deny_all |
| `sync_incoming_password` | string | "" | Password for incoming connections |
