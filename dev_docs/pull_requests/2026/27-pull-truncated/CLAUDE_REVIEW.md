# Claude review of PR #27: Mark pull-data answers cut at max_records_per_request and fail those pulls

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

Every path that touches the flag was read: only `pull_table_data` and `pull_table_data_with_remap` (HTTP) use it, both through `truncated?/1`. `Client`, `Receiver`, the WebSocket and the channel page with `request:records` and never touch `pull-data`, so #25's paging does not interact with it. The flag handling itself is correct.

## 1. IMPROVEMENT - HIGH: `api_controller.ex` pull-data, `pull_filter.ex`

`pull-data` has no cursor or offset, so a table over the limit cannot be fully pulled unless it has a single integer key. A `phoenix_kit_*` table (UUIDv7 key), a text-key or a composite-key table with 15,000 rows and a limit of 10,000 now fails every bulk pull with `:truncated`; before this PR it silently got the first 10,000. Precise Transfer by range answers `:unsupported_key_type` for those key types, and `max_records_per_request` is not in the connection form, so the only way out is `Connections.update_connection/2` in IEx. The error text points at "single integer key", a dead end for them.

**Resolution:** Not changed: a design call for the maintainer. Either add a keyset `after` cursor to `pull-data` (`WHERE pk > $after ORDER BY pk`, works for uuid, text and integer keys, the receiver loops until `truncated` is absent), or at least put `max_records_per_request` in the connection form and say so in the message.

## 2. IMPROVEMENT - MEDIUM: `connection_notifier.ex` retry list, `connections_live.ex`

A truncated parent table with children behind it gives pointless retries: the remap holds only the first rows' uuids, the children pointing at missing parents fail, that counts as `errors > 0` and triggers up to 3 retry passes that re-pull the same cut rows.

**Resolution:** Not changed. Skip `truncated: true` tables in the retry list, and warn about dependents of a truncated parent.

## 3. NITPICK: `api_controller.ex` `record_send/4`

Two writes (create `in_progress`, then complete or fail). If the second fails, the row stays `in_progress` and `Transfer.active?/1` reports it active forever; it also writes two activity rows per pull on the sender.

**Resolution:** Not changed. Insert with the final status, or wrap both writes in a transaction.

## 4. NITPICK: `api_controller.ex` `record_send/4`

The stored sender-side `error_message` is English text that mentions `Connections.update_connection/2`; History shows it as is and it cannot be translated.

**Resolution:** Not changed.

## 5. NITPICK: `transfer.ex` `changeset/2` (pre-existing)

Casts neither `started_at`, `completed_at` nor `records_transferred`, so the `started_at:` passed by `create_pull_transfer` is dropped and pull transfers never get a start time (History hides it, `duration_seconds` is nil).

**Resolution:** Not changed. Call `Transfers.start_transfer/1` after the create, or cast `started_at`.

## 6. NITPICK: `api_controller.ex` `key_order/1`

A table or view with no primary key is read with `LIMIT` and no `ORDER BY`; a truncated answer from it is nondeterministic and no pull can fetch the rest.

**Resolution:** Not changed. Same fix as the first finding.

