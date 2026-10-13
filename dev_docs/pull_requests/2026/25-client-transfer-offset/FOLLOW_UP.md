# Follow-up for PR #25: skipped rows and early ends in paged transfers

Reviews: `CLAUDE_REVIEW.md` (four findings), `GPT_REVIEW.md` (one, which
extends Claude's first). Each was re-read against the current code by reading
it.

## Fixed (pre-existing)

- ~~**Claude #4** Upgrade ordering to go in the CHANGELOG~~.
  `CHANGELOG.md:3-5` says "Upgrade receivers before senders" and why.

## Fixed (Batch 1 — 2026-10-13)

- ~~**Claude #1** A table with no primary key was paged with no
  `ORDER BY`~~. `lib/phoenix_kit_sync/data_exporter.ex:191-213`: with no
  `:order_by` and an empty primary key, `do_fetch_page/6` answers
  `{:error, :no_primary_key}` (the review's "refuse keyless tables").
- ~~**Claude #2** `batch_index: div(offset, @batch_size)`~~.
  `lib/phoenix_kit_sync/web/receiver.ex:755` passes `progress.jobs_queued`,
  incremented per queued batch at `:762`; `queue_import_job/5` uses it as
  given (`:1946-1956`).
- ~~**Claude #3** A sender that ignores `offset` kept the loop running~~.
  `lib/phoenix_kit_sync/client.ex:436-464` stops with `:paging_stalled` when a
  page starts with the previous page's first record, or at the offset cap.
  `receiver.ex:742` and `paging_stalled?/4` (`:1928-1942`) end the table
  the same way. Test: `test/phoenix_kit_sync/web/receiver_paging_test.exs:147`.

## Fixed (Batch 2 — 2026-10-13)

- ~~**GPT, IMPROVEMENT - MEDIUM** OFFSET paging of keyed tables under
  concurrent writes, over WebSocket and channel~~. `request:records`
  continues by key, with `PullCursor` as the only cursor implementation.
  Sender: `DataExporter.fetch_page/2`
  (`lib/phoenix_kit_sync/data_exporter.ex:115`) reads the rows after `:after`
  (`page_clause/3`, `:248-260`) and answers `next_after` (`:266-273`);
  `SyncWebsock` (`lib/phoenix_kit_sync/web/sync_websock.ex:372`, `:462-498`)
  and `SyncChannel` (`lib/phoenix_kit_sync/web/sync_channel.ex:207-223`) read
  `"after"` and add `"next_after"` to the reply. Receiver:
  `WebSocketClient` sends `after` beside the offset and hands on a
  well-formed `next_after` (`lib/phoenix_kit_sync/websocket_client.ex:249`,
  `:454`, `:560-565`); the `Client` loop
  (`lib/phoenix_kit_sync/client.ex:436-485`) and `Web.Receiver`
  (`lib/phoenix_kit_sync/web/receiver.ex:788`) carry it.
  `DataExporter.stream_records/2` continues by key as well (`:278-291`).
  Compatible both ways: a request without `"after"` is cut by its offset as
  before, and a reply without `"next_after"` is followed by offset; the key is
  added to a reply and never sent as null. `ChannelClient` and `ImportWorker`
  do not page, so neither changed. Tests:
  `test/integration/ws_keyset_paging_test.exs` (sender, both client layers,
  both peer generations, and a real transfer during which rows are deleted:
  by offset two rows are missed),
  `test/phoenix_kit_sync/web/sync_channel_test.exs:254`,
  `test/phoenix_kit_sync/web/receiver_paging_test.exs:67`.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_sync/data_exporter.ex` | 1, 2 | keyless tables refused; `fetch_page/2`, keyset stream |
| `lib/phoenix_kit_sync/client.ex` | 1, 2 | repeated-page and cap stop; position carried |
| `lib/phoenix_kit_sync/web/receiver.ex` | 1, 2 | repeated-page stop, running batch index; position carried |
| `lib/phoenix_kit_sync/web/sync_websock.ex`, `web/sync_channel.ex` | 2 | `after` in, `next_after` out |
| `lib/phoenix_kit_sync/websocket_client.ex` | 2 | `after` in the request, `next_after` from the reply |
| `test/integration/ws_keyset_paging_test.exs` | 2 | new |
| `test/phoenix_kit_sync/web/sync_channel_test.exs`, `web/receiver_paging_test.exs` | 2 | paging by key |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

- A table whose key type has no cursor (see PR #27's follow-up for the
  list) is still paged by `LIMIT … OFFSET` on this path:
  `lib/phoenix_kit_sync/data_exporter.ex:272-273`. Its rows can shift under
  concurrent writes as before; unlike the REST pull it is not cut, so the
  transfer completes.
