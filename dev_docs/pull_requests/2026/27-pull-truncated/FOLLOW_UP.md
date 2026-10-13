# Follow-up for PR #27: truncated pull-data answers

Reviews: `CLAUDE_REVIEW.md` (six findings), `GPT_REVIEW.md` (confirms #1 and
#2). Each was re-read against the current code by reading it.

## Fixed (pre-existing)

None.

## Fixed (Batch 1 — 2026-10-13)

- ~~**#1 (both reviews, HIGH)** `pull-data` had no continuation~~. Keyset
  cursor in `lib/phoenix_kit_sync/pull_cursor.ex`. The sender reads `after`
  (`lib/phoenix_kit_sync/web/api_controller.ex:542`), filters by it (`:1235`)
  and answers `next_after` plus a signed `cursor` (`:618-619`); the receiver
  loops on them and stops on a repeated page
  (`lib/phoenix_kit_sync/connection_notifier.ex:894-962`). Composite keys are
  covered when every column's type is. Tests:
  `test/integration/pull_cursor_sender_test.exs`,
  `pull_cursor_receiver_test.exs`, `pull_cursor_end_to_end_test.exs`.
- ~~**#2 (both reviews)** Truncated tables were retried~~.
  `lib/phoenix_kit_sync/web/connections_live.ex:956` leaves a table out of
  the retry list when its result has `truncated: true`; the flag is kept on
  the table result (`:1313`, `:1331`).
- ~~**#3** `record_send/4` made two writes~~. `api_controller.ex:1312-1327`
  calls `Transfers.record_finished/3`, one insert in the final status
  (`lib/phoenix_kit_sync/transfers.ex:193-204`).
- ~~**#4** Sender-side `error_message` was English text naming
  `Connections.update_connection/2`~~. The row stores the atom's name
  (`transfers.ex:197`, `:sent_truncated` at `api_controller.ex:1323`) and
  History shows it through `Errors.transfer_error/1`
  (`lib/phoenix_kit_sync/errors.ex:266`, `web/history.ex:641`).
- ~~**#5** `Transfer.changeset/2` dropped `started_at`~~.
  `lib/phoenix_kit_sync/transfer.ex:191` casts it; `create_pull_transfer`
  passes it (`connection_notifier.ex:864`).
- ~~**#6** A table with no primary key was read with no `ORDER BY`~~.
  `api_controller.ex:1203-1206`: `table_key/1` answers
  `{:error, :no_primary_key}`.

## Fixed (Batch 2 — 2026-10-13)

- ~~**#1, key types without a cursor**~~. `PullCursor`'s `@casts`
  (`lib/phoenix_kit_sync/pull_cursor.ex:38-55`) now also takes `character`,
  `real`, `double precision`, `boolean`, `bytea` and `time without time
  zone`: each orders alike under `ORDER BY` and the row comparison and reads
  back from its text as exactly the value (a float as its shortest
  round-trip text, with `NaN` and the infinities; `bytea` as hex). A float
  position is accepted only in that canonical text, so one Postgres would
  refuse is a 400. Left out, with the reason in the moduledoc (`:26-32`):
  `time with time zone` (Postgrex drops the zone, two keys can share a
  text), `interval` (no canonical text), `money` (locale-dependent text),
  enum, citext and other `USER-DEFINED` types (no type name to cast to, enum
  order is declaration order), network types, arrays, json. For those the
  sender names the type in the cut answer (`"unsupported_key_type"`,
  `PullCursor.unsupported_types/1` at `:74`,
  `api_controller.ex:624`), the receiver keeps it when it is a short
  printable string (`connection_notifier.ex:967-969`, `:1114-1127`) and the
  admin reads it on the table's row
  (`web/connections_live.ex:1225`, `errors.ex:224`). Tests:
  `test/integration/pull_cursor_sender_test.exs:184` (every new type walked page by page
  by rank), `:239` (bad positions refused) and `:294`,
  `pull_truncated_receiver_test.exs:67`,
  `test/phoenix_kit_sync/web/connections_live/pull_sync_test.exs:149`.
- ~~**#1, the limit could not be set**~~. The connection form of a sender
  connection has "Records per request"
  (`web/connections_live.ex:1991-2007`), bounded by
  `Connection.max_records_per_request_range/0`
  (`lib/phoenix_kit_sync/connection.ex:148`), which both changesets
  validate (`:312`, `:526`); the label and its help text are in the
  `et` and `ru` catalogues. Test:
  `test/phoenix_kit_sync/web/connections_live_test.exs:73`.
- ~~**From the review of the sweep, not of this PR: a cursor could be
  replayed for an hour without a download being counted**~~. The cursor's
  age is ten minutes (`api_controller.ex:643`). It was already free for
  its own position only, and a page's rows were already counted every time;
  both are now pinned, with the ages either side of the limit:
  `test/integration/pull_cursor_sender_test.exs:466`-`518`.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_sync/pull_cursor.ex` | 1, 2 | new: keyset cursor; six more key types, `unsupported_types/1` |
| `lib/phoenix_kit_sync/web/api_controller.ex` | 1, 2 | `after`/`cursor`, keyless refusal, one-write `record_send/5`; `unsupported_key_type`, cursor age |
| `lib/phoenix_kit_sync/connection_notifier.ex` | 1, 2 | page loop; the named key type kept |
| `lib/phoenix_kit_sync/web/connections_live.ex` | 1, 2 | truncated tables not retried; key-type message, form field |
| `lib/phoenix_kit_sync/transfer.ex`, `transfers.ex`, `errors.ex` | 1, 2 | `started_at` cast, `record_finished/3`, `transfer_error/1`; `{:truncated_key_type, type}` |
| `lib/phoenix_kit_sync/connection.ex` | 2 | bounds of `max_records_per_request` |
| `priv/gettext/` | 2 | new strings, `et` and `ru` filled |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

- A key of a type left out above still yields a cut answer with no
  continuation (`lib/phoenix_kit_sync/web/api_controller.ex:624`); the
  way out is the sender's "Records per request", which the message now says.
- `max_records_per_request` has no upper bound below the column's
  (`lib/phoenix_kit_sync/connection.ex:140`): whether a lower product limit
  is wanted is a maintainer decision.
- A page can be asked for again under its cursor within ten minutes without
  a download being counted (`lib/phoenix_kit_sync/web/api_controller.ex:643`); its records are
  counted. Closing that would take a stored per-pull state on the sender.
