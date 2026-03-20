# PR #1: Add PhoenixKitSync External Module Extracted from PhoenixKit

**Author**: @mdon (Max Don)
**Merged by**: @ddon (Dmitri Don)
**Status**: Merged
**Commit**: `a96e46c`
**Date**: 2026-03-20

## Goal

Extract the Sync module (peer-to-peer data sync between PhoenixKit instances) into a standalone external package following the same patterns as phoenix_kit_doc_forge and phoenix_kit_catalogue.

## What Was Changed

### Files Added (34 files, +16,443 lines)

| File | Description |
|------|-------------|
| `lib/phoenix_kit_sync.ex` (580) | Main module — config, admin tabs, child specs |
| `lib/phoenix_kit_sync/connection.ex` (486) | Ecto schema for sync connections |
| `lib/phoenix_kit_sync/connections.ex` (738) | Context for connection CRUD |
| `lib/phoenix_kit_sync/connection_notifier.ex` (1,637) | Remote HTTP client, data import, FK remapping |
| `lib/phoenix_kit_sync/session_store.ex` (279) | ETS-based ephemeral session store with process monitoring |
| `lib/phoenix_kit_sync/client.ex` (434) | Sync client wrapper |
| `lib/phoenix_kit_sync/channel_client.ex` (134) | Phoenix Channel client |
| `lib/phoenix_kit_sync/websocket_client.ex` (529) | WebSocket client with heartbeat |
| `lib/phoenix_kit_sync/data_exporter.ex` (223) | Query and stream records for export |
| `lib/phoenix_kit_sync/data_importer.ex` (417) | Import records with conflict strategies |
| `lib/phoenix_kit_sync/schema_inspector.ex` (542) | Database introspection (tables, columns, FKs) |
| `lib/phoenix_kit_sync/transfer.ex` (352) | Ecto schema for transfer history |
| `lib/phoenix_kit_sync/transfers.ex` (650) | Context for transfer CRUD |
| `lib/phoenix_kit_sync/routes.ex` (59) | Route macro for host app integration |
| `lib/phoenix_kit_sync/paths.ex` (16) | Centralized URL helpers |
| `lib/phoenix_kit_sync/column_info.ex` (39) | Struct for column metadata |
| `lib/phoenix_kit_sync/table_schema.ex` (27) | Struct for table metadata |
| `lib/phoenix_kit_sync/web/api_controller.ex` (1,294) | REST API for cross-site sync |
| `lib/phoenix_kit_sync/web/connections_live.ex` (2,829) | LiveView for managing connections |
| `lib/phoenix_kit_sync/web/receiver.ex` (2,045) | LiveView for receiving sync data |
| `lib/phoenix_kit_sync/web/sender.ex` (645) | LiveView for sending sync data |
| `lib/phoenix_kit_sync/web/history.ex` (670) | LiveView for transfer history |
| `lib/phoenix_kit_sync/web/index.ex` (240) | LiveView for sync dashboard |
| `lib/phoenix_kit_sync/web/socket_plug.ex` (290) | WebSocket upgrade plug |
| `lib/phoenix_kit_sync/web/sync_channel.ex` (212) | Phoenix Channel for sync protocol |
| `lib/phoenix_kit_sync/web/sync_socket.ex` (67) | Socket definition |
| `lib/phoenix_kit_sync/web/sync_websock.ex` (489) | WebSock handler with access control |
| `lib/phoenix_kit_sync/workers/import_worker.ex` (225) | Oban worker for background imports |
| `mix.exs` | Package definition and dependencies |
| `docs/table_structure.md` | Database table documentation |

## Implementation Details

- 26 modules copied and renamed from `PhoenixKit.Modules.Sync.*` to `PhoenixKitSync.*`
- Admin tabs use `live_view: {module, action}` tuples for auto-routing
- Route module provides API endpoints and WebSocket forward
- LayoutWrapper removed (admin layout applied automatically by live_session)
- Paths module centralizes URL helpers
- Table structure documented (migrations stay in PhoenixKit)
- ETS-based SessionStore for ephemeral sync sessions with process monitoring cleanup

## Features

- Ephemeral code-based transfers (one-time manual sync)
- Permanent token-based connections (recurring sync)
- Table-level access control with IP whitelists and time restrictions
- Conflict resolution strategies: skip, overwrite, merge, append
- FK remapping with UUID detection for cross-tenant sync
- Smart table exclusions (oban_*, schema_migrations, tokens)
