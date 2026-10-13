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

## Fixed (Batch 3 — 2026-10-13)

From the review of the sweep, not of this PR:

- ~~**The sender issued positions its own parser refused**~~. A key value's
  text may be 8192 bytes, on the way out and on the way in
  (`lib/phoenix_kit_sync/pull_cursor.ex:63`): `next_after/2` (`:167`)
  answers `{:too_long, type}` for a longer one rather than a position
  `from_params/1` would refuse, and `pull-data` then cuts the answer with
  `"unsupported_key_type": "text value over 8192 bytes"`
  (`lib/phoenix_kit_sync/web/api_controller.ex:1300`, `:631`). A `bytea`
  key is no longer held to 511 bytes, and a `numeric` one is written in
  plain digits at any length the cap allows (`pull_cursor.ex:224`) and
  accepted as such: before, a numeric key past 34 digits was sent and then
  refused. Tests: `test/integration/untrusted_names_and_shapes_test.exs:210`
  (long keys of each type issued, accepted and bound; values past the cap),
  `test/integration/pull_cursor_sender_test.exs:354` and `:372`.
- ~~**Two pulls at once could both take the last download, or the last
  records**~~. `Connections.reserve_transfer/2`
  (`lib/phoenix_kit_sync/connections.ex:1108`) takes the download and the
  page with one conditional `UPDATE` before a row is read; the answer is
  read with the granted count as its limit and then settled
  (`settle_transfer/3`, `:1174`) or given back (`cancel_transfer/1`,
  `:1193`). The rows served under a connection never exceed
  `max_records_total`; a request in flight holds its whole page until it
  settles. `pull-data`, `table-records` and the socket's `request:records`
  all go through it. Tests: `test/integration/transfer_limits_test.exs:139`
  and `:205` (twenty requests at once, outside the sandbox).
- ~~**`table-records` counted nothing**~~. Every answer is a download and
  its rows are records (`api_controller.ex:758`), so paging through it
  stops at both limits. Tests: `transfer_limits_test.exs:57`.
- ~~**A table read page by page over the WebSocket cost a download per
  page**~~. A request for exactly the position (or, from a peer that pages
  by offset, the offset) this socket's page before ended on, within ten
  minutes, continues that download
  (`lib/phoenix_kit_sync/web/sync_websock.ex:548-585`); the socket decides
  from what it answered, not from what the peer says. Its records count.
  Tests: `transfer_limits_test.exs:287`.

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
| `lib/phoenix_kit_sync/pull_cursor.ex` | 3 | one cap both ways, `{:too_long, type}`, numeric in plain digits |
| `lib/phoenix_kit_sync/connections.ex` | 3 | `reserve_transfer/2`, `settle_transfer/3`, `cancel_transfer/1` |
| `lib/phoenix_kit_sync/web/api_controller.ex` | 3 | reservation in `pull-data` and `table-records`; the too-long reason |
| `lib/phoenix_kit_sync/web/sync_websock.ex` | 3 | reservation; continuation pages tracked in the socket |

## Verification

`mix test` 2055 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

- A key of a type left out above, or a key value whose text is over 8192
  bytes, still yields a cut answer with no continuation
  (`lib/phoenix_kit_sync/web/api_controller.ex:631`); the way out is the
  sender's "Records per request", which the message now says.
- `max_records_per_request` has no upper bound below the column's
  (`lib/phoenix_kit_sync/connection.ex:140`): whether a lower product limit
  is wanted is a maintainer decision.
- A page can be asked for again under its cursor within ten minutes without
  a download being counted (`lib/phoenix_kit_sync/web/api_controller.ex:649`;
  on a socket, `lib/phoenix_kit_sync/web/sync_websock.ex:548`); its records
  are counted, and the record limit holds. Closing that over REST would
  take a stored per-pull state on the sender.
- The receiving site's 10-row preview is a `table-records` answer, so it
  spends one of the sender connection's downloads
  (`lib/phoenix_kit_sync/web/connections_live.ex:854`). Whether a preview
  should be free of one is a maintainer decision: an answer free of a
  download is bounded only by `max_records_total`.
