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
