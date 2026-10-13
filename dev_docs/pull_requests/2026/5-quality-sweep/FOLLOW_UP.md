# Follow-up for PR #5: quality sweep and re-validation

Review: `CLAUDE_REVIEW.md` (ten findings, four requested tests). Each was
re-read against the current code by reading it.

## Fixed (pre-existing)

- ~~**#3** `ConnectionsLive.mount/3` queried during the dead render~~.
  `lib/phoenix_kit_sync/web/connections_live.ex:55` calls
  `maybe_load_connections/1`, gated on `connected?(socket)` at
  `:66-74`. Requested test:
  `test/phoenix_kit_sync/web/connections_live_test.exs:292`.
- ~~**#4** Silent rescue in `log_sync_activity/4`~~. The rescue is gone:
  `lib/phoenix_kit_sync/connections.ex:79-96` calls
  `PhoenixKit.Activity.log/3`, and core's `log/1` rescues and writes a
  `Logger.warning` itself.
- ~~**#5** A no-op update wrote an audit row~~. `connections.ex:352` logs only
  `if changed_fields != []`. Requested test:
  `test/phoenix_kit_sync/connections_activity_test.exs:94`.
- ~~**#8** Untranslated `"Revoked by admin"`~~. `connections_live.ex:380`
  passes `gettext("Revoked by admin")`.

## Fixed (Batch 1 — 2026-10-13)

- ~~**#6** `String.t() | any()` specs~~. The catch-all functions are specced
  `term()`: `lib/phoenix_kit_sync/connection.ex:578`, `:589`, `:681`, `:694`.
  No `| any()` remains in `connection.ex`, `connections.ex` or `transfer.ex`.
- ~~**#9** Dead `safe_atom/1` fallback in `DataImporter`~~. Removed; the name
  occurs nowhere under `lib/`.
- ~~**#10** Actor passed positionally by some handlers~~. Every status handler
  passes `actor_uuid:` — `connections_live.ex:310`,
  `:334`,
  `:356`,
  `:379`,
  `:403`,
  `:425`. The positional clauses still
  exist in the context (`connections.ex:499`,
  `:551`,
  `:609`).

## Fixed (Batch 2 — 2026-10-13)

- ~~**#2** `terminate/2` cleanup without `trap_exit`~~. Both callbacks are
  removed; a comment in their place names what does the cleanup
  (`lib/phoenix_kit_sync/web/sender.ex:57`, `lib/phoenix_kit_sync/web/receiver.ex:88`).
  The sender's session is deleted by `SessionStore`'s monitor on its owner
  (`lib/phoenix_kit_sync/session_store.ex:252-275`); the
  receiver's client is started linked (`web/receiver.ex:477`), and a
  LiveView never stops with `:normal`, so the link always carries. The
  requested tests kill the LiveView and assert the session is gone and the
  client is down: `test/phoenix_kit_sync/web/live_process_cleanup_test.exs:24`, `:39`.
  They pin the cleanup, not the removal: `terminate/2` did run on a graceful
  stop (a closed tab), only not on a crash or a kill, so the callbacks were
  redundant rather than dead.
- ~~**#7** `@type t :: %__MODULE__{}`~~. Both structs are typed field by
  field: `lib/phoenix_kit_sync/connection.ex:80-129`,
  `lib/phoenix_kit_sync/transfer.ex:74-109`. Dialyzer passes with them.
- ~~**#1, tests** Pinning rows for the alternate IPv4 spellings~~.
  `test/phoenix_kit_sync/connection_ssrf_test.exs:147-156`: decimal
  (`2130706433`), octal (`0177.0.0.1`), hex (`0x7f.0.0.1`), the one-number
  hex and octal forms, the same spellings of a private and of the metadata
  address, and a public address in decimal that stays allowed. Each row runs
  under both schemes, with and without a port.

## Skipped (with rationale)

- **#1** Alternate IPv4 literal forms pass the SSRF guard. The review got
  this wrong: its table says `:inet.parse_address/1` answers `:error` for
  them, but it answers `{:ok, {127, 0, 0, 1}}` for `2130706433`,
  `0177.0.0.1`, `0x7f.0.0.1` and `127.1`, so `internal_host?/1`
  (`lib/phoenix_kit_sync/connection.ex:815-820`) refuses all four. Evidence: the rows above pass
  with no change to the guard.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_sync/connection.ex` | 1, 2 | `term()` specs on the catch-all functions; struct type |
| `lib/phoenix_kit_sync/data_importer.ex` | 1 | `safe_atom/1` and its lookups removed |
| `lib/phoenix_kit_sync/web/connections_live.ex` | 1 | `actor_uuid:` on every status call |
| `lib/phoenix_kit_sync/transfer.ex` | 2 | struct type |
| `lib/phoenix_kit_sync/web/sender.ex`, `web/receiver.ex` | 2 | `terminate/2` removed |
| `test/phoenix_kit_sync/connection_ssrf_test.exs` | 1, 2 | host table; the other IPv4 spellings |
| `test/phoenix_kit_sync/web/live_process_cleanup_test.exs` | 2 | new: kill the LiveView, session and client are gone |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

None.
