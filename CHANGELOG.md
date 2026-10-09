## 0.2.4 - 2026-10-09

Ten PRs (#18 to #27) and their review fixes. **Upgrade receivers before
senders:** a receiver older than this release still skips rows when a
sender's `max_records_per_request` is below its batch size.

### Fixed

- **Pulls of composite-key tables** use the whole key (`ON CONFLICT (a, b)`);
  a pull that raised no longer leaves its transfer `in_progress` or the page
  stuck on "syncing" (#18).
- **Identifiers from the sender are validated and quoted** before any SQL
  runs, inserts write only columns the local table has, and Create Table
  works over HTTP (#19).
- **FK remaps** work for uuid and integer keys, `overwrite`/`merge` update
  the matched row on a remap pull, and text keys stay distinct instead of
  being folded as uuids. Whole-number and exponent strings (`"5"`,
  `"1.5E+3"`) now become `Decimal` in numeric columns (#20).
- **Precise Transfer applies its ID filter on the sender**, for `pull-data`
  and `table-records`, including remap pulls; a sender that ignores the
  filter is refused. Zero-padded IDs (`007`) are sent as typed, not as 7 (#21).
- **Bad `page`, `offset` and `limit` values** no longer crash History, the
  API, the WebSocket or the channel (#22).
- **uuid and `bytea` columns over WebSocket and channel** are exported as
  text and a wrapper, and imported back by the target column's type (#23).
- **Paged transfers no longer skip rows or end early** when a sender returns
  fewer rows than requested; they read to an empty page (#25).
- **Array columns** round-trip over WebSocket and channel, and Create Table
  builds them from their element type (#26).
- **`table-records`** orders by the whole primary key.
- Sync errors show their `Errors` message instead of `Sync failed: :atom`.

### Changed

- **A `pull-data` answer cut at `max_records_per_request` now fails the
  transfer** (`:truncated`) instead of passing as complete. The rows that
  came are imported. A table over the limit with a non-integer or composite
  key cannot be pulled in full until `pull-data` gets a cursor (#27).
- **Tables that are never synced are refused on both sides:**
  `schema_migrations`, `oban_*`, `pg_*` and the session-token table
  (`phoenix_kit_users_tokens`, plus the old `phoenix_kit_user_tokens`
  spelling). The sender enforces it on explicit requests; the receiver
  refuses them from a sender's list (`:table_excluded`).
- Updated `mint` to 1.10.2 for three security advisories (#24).

## 0.2.3 - 2026-09-26

### Changed

- **Requires `phoenix_kit >= 2.38.0 and < 3.0.0`.** Connection and transfer
  pages read the acting admin through `PhoenixKitWeb.Actor`. Activity rows
  go through `PhoenixKit.Activity.log/3`: admin actions stay `mode: "manual"`,
  and the import worker still logs `mode: "auto"` with no actor. Core never
  raises from that call, so a missing activities table no longer fails the
  operation (#17).
- **Admin header trails.** Overview, Connections, History, Send and Receive
  feed core's header bar: the section is Sync (except Overview, which is the
  landing page) and the title is only this page. Opening, editing or syncing
  a connection keeps the levels above it — `Sync / Connections / <name> / Edit`.
- The connections sync tab strip uses core's `<.nav_tabs>` (#15).
- Locked `phoenix_kit` 2.40.1.

### Fixed

- **`sync.connection.created` now records the creator.** The connection row
  already stored `created_by_uuid`; the activity was logged with no actor.

## 0.2.2 - 2026-08-21

### Changed

- **The receiver's Bulk Transfer / Table Details strip uses core's
  `<.nav_tabs>`**, replacing a hand-rolled copy that still carried
  daisyUI 4's `tabs-boxed` (#14).

### Fixed

- **`version/0`'s test asserted `"0.1.0"`** while the package has been
  at 0.2.x since the core 2.0 pin. It now tracks the published version
  (post-merge).
- **Four tests passed a random UUID as an approve/deny/revoke actor**,
  which raises on the real `phoenix_kit_users` FKs. They now use
  `PhoenixKitSync.TestActor` like the rest of the suite (post-merge,
  surfaced by core 2.13.5).

## 0.2.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.2.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

## 0.1.6 - 2026-06-08

### Added
- `pk_dep/3` in `mix.exs`: a `phoenix_kit*` dep resolves from Hex by default, but
  exporting `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit`) swaps the Hex
  pin for a local `path:` + `override: true` dep at resolve time, for cross-repo
  development against an unpublished core checkout. With the var unset (or blank),
  resolution is identical to before — nothing path-based ships. See the "Local
  cross-repo development" section in `AGENTS.md`.

### Changed
- Updated locked dependency versions (`mix.lock`); declared constraints in
  `mix.exs` are unchanged.

## 0.1.5 - 2026-05-21

### Fixed
- `ConnectionNotifier` no longer hardcodes `/phoenix_kit` as the remote API
  path prefix when notifying remote sites (issue #8). It now derives the
  prefix from the local site's `PhoenixKit.Config.get_url_prefix/0`, which
  mirrors the remote in symmetric deployments — the common case — so the
  default routing (no custom prefix) stops returning `404 Not Found` on
  `register-connection` and the other sync API calls. Deployments whose
  remote uses a different prefix than the local site can override it with
  `config :phoenix_kit_sync, remote_url_prefix: "/custom"`. The prefix is
  normalized (leading slash ensured, trailing slash stripped, `""`/`"/"`
  collapsed to no prefix), and the ten near-identical URL builders were
  collapsed onto a single `build_sync_url/2` helper.

## 0.1.4 - 2026-05-13

### Fixed
- `ConnectionNotifier.format_error/1` now correctly formats the `Finch.*`
  exception structs that `Finch.request/3` actually returns at runtime.
  PR #9 reverted these heads to `Mint.TransportError` / `Mint.HTTPError`
  to unblock parent-app builds where Finch wasn't loaded at compile time,
  but Finch wraps every `Mint.*` error via `Finch.Error.wrap/1` before
  returning, so the `Mint.*` heads never matched in production and errors
  fell through to the `inspect/1` catch-all. The `Finch.*` heads are now
  restored and gated with `Code.ensure_loaded?/1` so the module still
  compiles cleanly when Finch isn't loaded in the parent build.

## 0.1.3 - 2026-05-12

### Fixed
- Dialyzer: `ConnectionNotifier.format_error/1` matched `Mint.TransportError`,
  but Finch returns `Finch.TransportError`/`Finch.HTTPError`/`Finch.Error`
  (Mint errors are wrapped as the `source` of `Finch.TransportError`). The
  unreachable pattern is replaced with the three Finch error structs.

## 0.1.2 - 2026-05-05

### Changed
- Test schema setup now uses `PhoenixKit.Migration.ensure_current/2` (requires
  `phoenix_kit` 1.7.105+) instead of hand-rolled inline DDL — eliminates schema
  drift between test and production by construction.

### Fixed
- LiveView Iron Law: `ConnectionsLive.mount/3` no longer queries the DB during
  the HTTP dead render; `load_connections/1` is gated on `connected?(socket)`.
- LiveView Iron Law: `ConnectionsLive.handle_params/3` `show`/`edit`/`sync`
  branches no longer query the DB during the dead render of deep-linked URLs.
- F4 revoke gettext test now correctly mounts into the connection detail view
  (where the revoke button lives) via deep-link URL.

## 0.1.1 - 2026-04-11

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.0 - 2026-03-21

### Added
- Initial release of PhoenixKitSync as a standalone package
- Peer-to-peer data sync between PhoenixKit instances (dev-prod, dev-dev, cross-site)
- WebSocket-based real-time data transfer with session codes and permanent token auth
- Permanent connections with access controls (IP whitelist, allowed hours, download/record limits)
- Transfer history with approval workflow (auto-approve, require-approval, per-table)
- Conflict resolution strategies: skip, overwrite, merge, append
- Background import via Oban workers with batched processing
- Database schema introspection and table discovery
- LiveView UI for connections management, transfer history, sender/receiver flows
- API endpoint for automatic cross-site connection registration
- Programmatic API for scripted and AI-agent-driven sync operations
