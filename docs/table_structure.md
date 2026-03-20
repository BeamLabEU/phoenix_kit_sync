# PhoenixKitSync Database Tables

Migrations for these tables are managed by PhoenixKit's core migration system
(not by this package). This document describes the expected schema.

## phoenix_kit_sync_connections

Permanent, token-based connections between PhoenixKit sites.

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| uuid | UUIDv7 | NO | autogenerate | Primary key |
| name | varchar | NO | | Connection display name |
| direction | varchar | NO | | "sender" or "receiver" |
| site_url | varchar | NO | | Remote site URL |
| auth_token_hash | varchar | YES | | SHA256 hash of auth token |
| status | varchar | NO | "pending" | pending/active/suspended/revoked/expired |
| approval_mode | varchar | NO | "auto_approve" | auto_approve/require_approval/per_table |
| allowed_tables | text[] | NO | {} | Whitelist (empty = all) |
| excluded_tables | text[] | NO | {} | Blacklist |
| auto_approve_tables | text[] | NO | {} | Tables that skip approval |
| expires_at | utc_datetime | YES | | Expiration timestamp |
| max_downloads | integer | YES | | Download operation limit |
| downloads_used | integer | NO | 0 | Counter |
| max_records_total | integer | YES | | Total record limit |
| records_downloaded | integer | NO | 0 | Counter |
| max_records_per_request | integer | NO | 10000 | Per-request limit |
| rate_limit_requests_per_minute | integer | NO | 60 | Rate limit |
| download_password_hash | varchar | YES | | SHA256 hash |
| ip_whitelist | text[] | NO | {} | Allowed IPs |
| allowed_hours_start | integer | YES | | 0-23 |
| allowed_hours_end | integer | YES | | 0-23 |
| default_conflict_strategy | varchar | NO | "skip" | skip/overwrite/merge/append |
| auto_sync_enabled | boolean | NO | false | |
| auto_sync_tables | text[] | NO | {} | |
| auto_sync_interval_minutes | integer | NO | 60 | |
| approved_at | utc_datetime | YES | | |
| suspended_at | utc_datetime | YES | | |
| suspended_reason | varchar | YES | | |
| revoked_at | utc_datetime | YES | | |
| revoked_reason | varchar | YES | | |
| last_connected_at | utc_datetime | YES | | |
| last_transfer_at | utc_datetime | YES | | |
| total_transfers | integer | NO | 0 | |
| total_records_transferred | integer | NO | 0 | |
| total_bytes_transferred | integer | NO | 0 | |
| metadata | jsonb | NO | {} | |
| approved_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| suspended_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| revoked_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| created_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| inserted_at | utc_datetime | NO | | |
| updated_at | utc_datetime | NO | | |

**Unique constraint:** `(site_url, direction)` — `phoenix_kit_sync_connections_site_direction_uidx`

## phoenix_kit_sync_transfers

Transfer history with approval workflow.

| Column | Type | Nullable | Default | Notes |
|--------|------|----------|---------|-------|
| uuid | UUIDv7 | NO | autogenerate | Primary key |
| direction | varchar | NO | | "send" or "receive" |
| session_code | varchar | YES | | 8-char ephemeral code |
| remote_site_url | varchar | YES | | |
| table_name | varchar | NO | | Target table |
| records_requested | integer | NO | 0 | |
| records_transferred | integer | NO | 0 | |
| records_created | integer | NO | 0 | |
| records_updated | integer | NO | 0 | |
| records_skipped | integer | NO | 0 | |
| records_failed | integer | NO | 0 | |
| bytes_transferred | integer | NO | 0 | |
| conflict_strategy | varchar | YES | | skip/overwrite/merge/append |
| status | varchar | NO | "pending" | pending/pending_approval/approved/denied/in_progress/completed/failed/cancelled/expired |
| requires_approval | boolean | NO | false | |
| approved_at | utc_datetime | YES | | |
| denied_at | utc_datetime | YES | | |
| denial_reason | varchar | YES | | |
| approval_expires_at | utc_datetime | YES | | |
| requester_ip | varchar | YES | | |
| requester_user_agent | varchar | YES | | |
| error_message | text | YES | | |
| started_at | utc_datetime | YES | | |
| completed_at | utc_datetime | YES | | |
| metadata | jsonb | NO | {} | |
| connection_uuid | UUIDv7 | YES | | FK → phoenix_kit_sync_connections |
| approved_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| denied_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| initiated_by_uuid | UUIDv7 | YES | | FK → phoenix_kit_users |
| inserted_at | utc_datetime | NO | | |

**Note:** `updated_at` is NOT present (transfers are append-only with status transitions).

## Settings Keys

Stored in `phoenix_kit_settings` table:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `sync_enabled` | boolean | false | Module enable/disable |
| `sync_incoming_mode` | string | "require_approval" | auto_accept/require_approval/require_password/deny_all |
| `sync_incoming_password` | string | "" | Password for incoming connections |
