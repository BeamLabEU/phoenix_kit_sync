# Claude review of PR #29: Fix paging of tables without a primary key

**Reviewer**: Claude (read-only pass over the PR diff and the current code it touches; the DB-backed tests were not run, there is no database in the review environment).

`DataExporter.fetch_single_page/3` reads `limit + 1` rows of a keyless table, refuses it (`:no_primary_key`) when more than `limit` came back and otherwise answers the rows past `:offset`. Read against `fetch_page`, `SyncWebsock.fetch_records_for_table` (reservation, `granted/2`, cancel on error) and `ApiController` (which still refuses every keyless table): the logic is right, the page after the last is empty, a position (`:after`) is still refused and `build_order_clause([])` keeps the query valid. No bug found.

## 1. NITPICK: `data_exporter.ex` `fetch_single_page/3` under a token connection

The sender passes `reservation.records` as the limit, so a keyless table that fits the requested page but not the connection's remaining record budget answers `:no_primary_key` rather than a limit message. The reservation is cancelled on the error, so nothing is charged.

**Resolution:** Not changed.

## 2. NITPICK: `errors.ex` `:no_primary_key`

The text ("Not pulled: the table has no primary key here...") is written for the receiving side; a socket peer now also gets `:no_primary_key` for a *source* table too large for one page, and the sender's reply is `inspect(reason)` (see PR #28, finding 14).

**Resolution:** Not changed.
