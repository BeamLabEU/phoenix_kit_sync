# PhoenixKitSync

Peer-to-peer data sync module for [PhoenixKit](https://github.com/mdon/phoenix_kit).

Provides bidirectional data synchronization between PhoenixKit instances —
sync between dev and prod, dev and dev, or different websites entirely.

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_sync, path: "../phoenix_kit_sync"}
```

The module is auto-discovered via PhoenixKit's beam scanning — no additional
configuration needed. Enable it from the admin dashboard under Modules.

## Features

- Ephemeral code-based transfers (one-time manual sync)
- Permanent token-based connections (recurring sync)
- Table-level access control with IP whitelists and time restrictions
- Conflict resolution strategies: skip, overwrite, merge, append
- Transfer approval workflow with expiration
- Real-time progress tracking
- Background import via Oban workers
- Cross-site HTTP API + WebSocket protocol

## Database

Table migrations are managed by PhoenixKit's core migration system.
See [docs/table_structure.md](docs/table_structure.md) for schema documentation.
