# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Sync — an Elixir module for peer-to-peer data synchronization between PhoenixKit instances, built as a pluggable module for the PhoenixKit framework. Supports sync between dev↔prod, dev↔dev, or different websites entirely. Provides admin LiveViews for managing connections/transfers, REST API and WebSocket endpoints for cross-site communication, and Oban-based background import.

## Commands

```bash
mix test                    # Run all tests (integration excluded if no DB)
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix deps.get                # Install dependencies
```

## Dependencies

This is a **library**, not a standalone app. It requires a sibling `../phoenix_kit` directory (path dependency). The full dependency chain:

- `phoenix_kit` (path: `"../phoenix_kit"`) — provides Module behaviour, Settings, RepoHelper, Dashboard tabs
- `phoenix`, `phoenix_live_view` — web framework
- `ecto_sql`, `postgrex` — database (via phoenix_kit)
- `websockex` — WebSocket client for connecting to remote senders
- `oban` — background job processing for imports
- `jason` — JSON encoding/decoding

## Architecture

This is a **PhoenixKit module** that implements the `PhoenixKit.Module` behaviour. It depends on the host PhoenixKit app for Repo, Endpoint, and Settings.

### Core Schemas

- **Connection** (`phoenix_kit_sync_connections`) — permanent token-based connection to a remote site, with auth token, table access config, IP whitelists, and time restrictions
- **Transfer** (`phoenix_kit_sync_transfers`) — transfer history record tracking direction, status, tables synced, and record counts

### Sync Modes

1. **Ephemeral code-based transfers** — one-time manual sync using a short-lived session code. SessionStore (ETS + GenServer with process monitoring) manages these sessions.
2. **Permanent token-based connections** — recurring sync using stored auth tokens with table-level access control.

### Data Pipeline

- **SchemaInspector** — database introspection (tables, columns, FKs, row counts)
- **DataExporter** — query and stream records for export with pagination
- **DataImporter** — import records with conflict strategies (skip, overwrite, merge, append)
- **ConnectionNotifier** — remote HTTP client for cross-site notifications, FK remapping, record transformation

### Communication Layer

- **Client / ChannelClient / WebSocketClient** — client-side sync protocol over WebSocket with heartbeat
- **ApiController** — REST API for cross-site sync operations (register, delete, verify connections; list tables; pull data)
- **SyncChannel / SyncSocket / SyncWebsock** — server-side WebSocket and Channel handlers
- **SocketPlug** — WebSocket upgrade plug

### Web Layer

- **Admin** (5 LiveViews): Index (dashboard), ConnectionsLive (manage connections), Receiver (receive data), Sender (send data), History (transfer log)
- **Public** (API + WebSocket): `ApiController` handles REST endpoints; `SyncSocket`/`SyncChannel` handle WebSocket sync protocol
- **Routes**: `route_module/0` provides public routes; admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Background Workers

- **ImportWorker** — Oban worker for large batch imports (max 3 retries)

### Settings Keys

`sync_enabled`, `sync_incoming_mode`, `sync_incoming_password`

### API Endpoints

All under the configured URL prefix (default: `/phoenix_kit`):

| Method | Path | Handler | Auth |
|--------|------|---------|------|
| POST | `/sync/api/register-connection` | Register incoming connection | Incoming mode + optional password |
| POST | `/sync/api/delete-connection` | Delete a connection | Module enabled |
| POST | `/sync/api/verify-connection` | Verify connection exists | Module enabled |
| POST | `/sync/api/update-status` | Update connection status | Module enabled |
| POST | `/sync/api/get-connection-status` | Query connection status | Module enabled |
| POST | `/sync/api/list-tables` | List available tables | Token + active connection |
| POST | `/sync/api/pull-data` | Pull table data | Token + active connection |
| POST | `/sync/api/table-schema` | Get table schema | Token + active connection |
| POST | `/sync/api/table-records` | Get table records | Token + active connection |
| GET | `/sync/api/status` | Check module status | None |
| WS | `/sync/websocket` | WebSocket sync protocol | Code or token in query params |

### File Layout

```
lib/phoenix_kit_sync.ex                    # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_sync/
├── connection.ex                          # Connection Ecto schema + changesets
├── connections.ex                         # Connections context (CRUD, validation)
├── transfer.ex                            # Transfer Ecto schema + changesets
├── transfers.ex                           # Transfers context (CRUD, lifecycle)
├── schema_inspector.ex                    # DB introspection (tables, columns, FKs)
├── data_exporter.ex                       # Record export with pagination + streaming
├── data_importer.ex                       # Record import with conflict strategies
├── connection_notifier.ex                 # HTTP client for remote site communication
├── session_store.ex                       # ETS-based ephemeral session management
├── column_info.ex                         # Column metadata struct
├── table_schema.ex                        # Table schema struct
├── client.ex                              # High-level sync client API
├── channel_client.ex                      # Channel-based sync client
├── websocket_client.ex                    # WebSockex-based sync client
├── paths.ex                               # Centralized URL path helpers
├── routes.ex                              # Route generation macro
├── migration.ex                           # Standalone migration (IF NOT EXISTS)
├── web/
│   ├── api_controller.ex                  # REST API for cross-site operations
│   ├── sync_websock.ex                    # WebSocket handler (WebSock behaviour)
│   ├── sync_channel.ex                    # Phoenix Channel handler
│   ├── sync_socket.ex                     # Phoenix Socket for channels
│   ├── socket_plug.ex                     # WebSocket upgrade plug
│   ├── index.ex                           # Admin dashboard LiveView
│   ├── connections_live.ex                # Admin connections management LiveView
│   ├── sender.ex                          # Admin sender LiveView
│   ├── receiver.ex                        # Admin receiver LiveView
│   └── history.ex                         # Admin transfer history LiveView
└── workers/
    └── import_worker.ex                   # Oban worker for batch imports
```

## Key Conventions

- **UUIDv7 primary keys** — all schemas use UUIDv7 primary keys
- **Oban workers** — all background tasks use Oban workers; never spawn bare Tasks for async import work
- **Centralized paths via `Paths` module** — never hardcode URLs or route paths in LiveViews or controllers; use `Paths` helpers
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere
- **Public routes from `route_module/0`** — the single public entry point is `PhoenixKitSync.Routes`; `route_module/0` returns this module so PhoenixKit registers public routes automatically
- **LiveViews use `Phoenix.LiveView` directly** — do not use `PhoenixKitWeb` macros (`use PhoenixKitWeb, :live_view`) in this standalone package; import helpers explicitly
- **SQL identifier safety** — always validate table/column names with `valid_identifier?/1` and quote with `quote_identifier/1` before using in raw SQL
- **`Connection.ip_allowed?/2` quirk** — when `ip_whitelist` is empty (allow all), calling `ip_allowed?(conn, "127.0.0.1")` returns `false` because the 2-arity clause doesn't match the empty-list guard. The 1-arity `ip_allowed?(conn)` works correctly. Callers like `Connections.validate_connection/2` pass `nil` as IP to avoid this
- **Self-connection protection** — `Connections.create_connection/1` rejects sender connections to the site's own URL (with port/scheme/case normalization). Only applies to direction `"sender"` — receivers (API-created) are always allowed
- **PubSub broadcasts from context** — all state-changing operations in `Connections` broadcast via PubSub (`:connection_created`, `:connection_deleted`, `:connection_status_changed`, `:connection_updated`). Don't add duplicate broadcasts in controllers or LiveViews
- **Decimal values in sync** — `DataExporter` serializes `Decimal` to strings for JSON. `ConnectionNotifier.prepare_value/1` parses decimal-like strings (e.g., `"0.00"`) back to `Decimal` structs before INSERT. Without this, numeric columns fail with Postgrex type errors
- **Suggested tables in sync UI** — when tables are selected for sync, tables that reference them via FK are highlighted (not auto-selected) as "suggested". The admin decides whether to include them

## Testing

### Setup

The test database must be created manually:

```bash
createdb phoenix_kit_sync_test
mix test
```

Integration tests are automatically excluded when the database is unavailable. The test helper creates the `uuid_generate_v7()` function and runs `PhoenixKitSync.Migration` on first run.

The critical config wiring is in `config/test.exs`:

```elixir
config :phoenix_kit, repo: PhoenixKitSync.Test.Repo
```

Without this, all DB calls through `PhoenixKit.RepoHelper` crash with "No repository configured".

### Structure

```
test/
├── test_helper.exs                  # DB detection, migration, sandbox setup
├── support/
│   ├── test_repo.ex                 # PhoenixKitSync.Test.Repo
│   ├── data_case.ex                 # DataCase (sandbox + :integration tag)
│   └── changeset_helpers.ex         # errors_on/1 helper
├── phoenix_kit_sync/                # Unit tests (no DB, async: true)
│   ├── module_test.exs              # PhoenixKit.Module behaviour compliance
│   ├── connection_test.exs          # Connection changesets, access controls
│   ├── transfer_test.exs            # Transfer changesets, status logic
│   ├── session_store_test.exs       # ETS CRUD, process monitoring
│   ├── ephemeral_session_test.exs   # Session lifecycle via public API
│   ├── import_worker_test.exs       # Oban job changeset building
│   └── paths_test.exs              # URL path helpers
└── integration/                     # Integration tests (needs DB)
    ├── connections_test.exs         # Connections CRUD, validation, PubSub, self-connection
    ├── transfers_test.exs           # Transfer lifecycle + approval workflow
    ├── migration_test.exs           # Table structure verification
    ├── schema_inspector_test.exs    # Table listing, schema, checksums
    ├── data_exporter_test.exs       # Count, fetch, pagination, streaming
    ├── data_importer_test.exs       # All 4 conflict strategies
    ├── api_controller_test.exs      # Business logic + access control
    ├── sync_websock_test.exs        # WebSocket access control logic
    └── full_sync_flow_test.exs      # End-to-end export → import cycle
```

### Key patterns

- **Use string keys** for `Connections.create_connection/1` attrs — it injects a string key internally, causing `Ecto.CastError` with atom keys
- **Use `UUIDv7.generate()`** for any user UUID field (`approved_by_uuid`, etc.) — plain strings cause `Ecto.ChangeError`
- **Tag DB tests via `DataCase`** — the `@moduletag :integration` is set automatically
- **`enabled?/0` and `get_config/0` hit the DB** — test with `function_exported?/3` in unit tests, or tag as `:integration`
- **SessionStore uses a global ETS table** — use `setup_all` with `{:error, {:already_started, _}}` handling, not per-test `start_link`
- **Ecto schema types** — use `:integer` (not `:bigint`) and `:string` (not `:text`) in schemas; the migration-only types cause compilation errors
- **Run migrations via `Ecto.Migrator.up/4`** — calling `Migration.up()` directly fails outside a migrator process

### Running tests

```bash
mix test                             # All tests (excludes integration if no DB)
mix test test/phoenix_kit_sync/      # Unit tests only
mix test test/integration/           # Integration tests only
mix test --only integration          # Only integration-tagged tests
```

## PR Reviews

PR reviews are stored in `dev_docs/pull_requests/` and tracked in version control.

### Structure

```
dev_docs/pull_requests/<year>/<pr_number>-<slug>/CLAUDE_REVIEW.md
```

- **`<year>`** — year the PR was created (e.g., `2026`)
- **`<pr_number>`** — GitHub PR number (e.g., `1`)
- **`<slug>`** — short kebab-case summary from the PR title (e.g., `sync-module-extraction`)
- **`CLAUDE_REVIEW.md`** — the review file, always named `CLAUDE_REVIEW.md`

### Review file format

```markdown
# Claude's Review of PR #<number> — <title>

**Verdict:** <Approve | Approve with follow-up items | Needs Work> — <reasoning>

## Critical Issues
### 1. <title>
**File:** <path>:<lines>
<Description, code snippet, fix>

## Security Concerns
## Architecture Issues
## Code Quality
### Issues
### Positives

## Recommended Priority
| Priority | Issue | Action |
```

Severity levels: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`

When issues are fixed in follow-up commits, append `— FIXED` to the issue title.

Additional files per PR directory:
- `README.md` — PR summary (what, why, files changed)
- `FOLLOW_UP.md` — post-merge issues, discovered bugs
- `CONTEXT.md` — alternatives considered, trade-offs
