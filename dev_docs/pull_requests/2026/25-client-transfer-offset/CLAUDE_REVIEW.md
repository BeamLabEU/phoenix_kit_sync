# Claude review of PR #25: Fix skipped rows and early ends in paged transfers

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

Paging logic read end to end: sender pages are primary-key ordered, the WebSocket handler caps at `max_limit` and then at the connection's `max_records_per_request`, and both consumers advance by `length(records)`. No skip or double-read found for keyed tables.

## 1. IMPROVEMENT - MEDIUM: `data_exporter.ex` `build_order_clause/1` (pre-existing)

A table with no primary key gets no `ORDER BY`. Offset paging over an unordered heap can skip or repeat rows if the table is written between pages, so the no-skip guarantee holds only for keyed tables.

**Resolution:** Not changed. Fall back to `ORDER BY ctid` or refuse keyless tables, as pull-data does.

## 2. NITPICK: `receiver.ex` `batch_index: div(offset, @batch_size)`

Wrong when the sender returns fewer rows than asked: with a cap of 100, offsets 0..400 all give index 0. The index is only logged, with no Oban uniqueness on it.

**Resolution:** Not changed. Use a running batch counter if it ever matters.

## 3. NITPICK: `receiver.ex`, `client.ex`

The loop now ends only on an empty page. A sender that ignored `offset` and returned the same page forever would loop; no sender in this codebase does.

**Resolution:** Not changed.

## 4. NITPICK: Upgrade ordering

A pre-#25 WebSocket receiver talking to a sender with `max_records_per_request` below its batch size still skips rows, because it advances by `batch_size`. This is the bug the PR fixes on the receiver side.

**Resolution:** To go in the release CHANGELOG: upgrade receivers first.

