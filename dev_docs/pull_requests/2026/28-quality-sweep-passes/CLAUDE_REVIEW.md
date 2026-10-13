# Claude review of PR #28: Quality sweep passes 1 to 3 (merge of mdon/main)

**Reviewer**: Claude (read-only pass over the PR diff and the current code it touches, split into three slices read in parallel: connections/transfers/sessions, sender-side REST and sockets, receiver/import/UI; findings below were checked against the code. The DB-backed tests were not run, there is no database in the review environment).

The PR is large (101 files, about 20k lines, mostly tests and catalogues). The design held up on everything the three slices tried to break: authorization goes through `authorize_request/3` on every table-reading path; the reservation arithmetic (`reserve`/`settle`/`cancel`) neither overshoots nor leaks outside a dying process; every interpolated SQL name is validated and quoted; the cursor binds connection, table and position; `Errors.message/1` has a clause for every atom `lib` emits; the registration lock, cap and duplicate check are correct. The findings are narrow.

Severity labels follow AGENTS.md. "Fixed" means changed in the review commit; everything else is on record for the maintainer.

## Fixed

### 1. BUG - MEDIUM: a peer-chosen `conflict_strategy` silently drops the sender's history row

`Validators.conflict_strategy/1` accepted any non-empty string; `Transfer` only takes `skip|overwrite|merge|append`, so `Transfers.record_finished/2` returned `{:error, changeset}`, which `record_send/5` ignores. The rows were served and charged, with no History row.

**Resolution:** Fixed. The validator keeps the four strategies and falls back to `skip` (test in `validators_test.exs`). `record_send` still ignores a failed insert.

### 2. BUG - MEDIUM: REST `serialize_value/1` had no fallback for tuples and bitstrings, and the failure comes after the charge

A composite column (tuple) or `bit(n)` (bitstring) is not encodable by Jason. `pull_data` calls `settle_transfer` and `record_send` before `json/2`, so each failed attempt answers 500 and still burns a download and the page of records.

**Resolution:** Fixed in part: both go as the unsupported marker (`ExtensionTypes.unsupported_marker/1`), which fails only their record on import, like the other types without a wire form. Not changed: encoding the body before settling.

### 3. BUG - MEDIUM: a non-string sender status crashes the Connections LiveView

`parse_status_response/1` returned `{:ok, status}` for any JSON value; `resolve_sender_status/1` has no clause for it, the linked task raises, and the page dies on every load (the admin cannot reach Delete).

**Resolution:** Fixed. Only a binary status is `{:ok, status}`, anything else is `:invalid_response`, which is all `resolve_sender_status/1` has clauses for (the type is closed by the spec; dialyzer rejects a catch-all there).

### 4. BUG - MEDIUM: `Receiver` crashes on a non-string peer `error`

`response:error` carries any JSON term; `receiver.ex` interpolates or `to_string`s it (lines about 650, 693, 862, 867, 1927) and raises for a map.

**Resolution:** Fixed at the boundary: `WebSocketClient` hands on text, or `:invalid_response` for anything else. The raw term is logged with `limit: 5`.

### 5. BUG - MEDIUM: credential prefixes in logs

`validate_connection/3` logged the first 8 characters of the raw socket token on every failed validation; the registration and connection-created lines logged 8 characters of `auth_token_hash` (the REST credential). AGENTS.md: credentials stay out of logs.

**Resolution:** Fixed. The three prefixes are gone (`connections.ex`, `api_controller.ex`, `connections_live.ex`).

### 6. IMPROVEMENT - MEDIUM: `ImportWorker` logged whole records

`log_import_errors/2` logged `inspect(record)` at debug and `inspect(error)` at warning. `phoenix_kit_users` is synced, so a failing row can carry `hashed_password`, and a database error can quote the row.

**Resolution:** Fixed. The record is no longer logged; the warning carries the key and the error cut to 120 printable bytes. (`DataImporter` lines 164 and 187 still log `inspect(e)` of an exception; not changed.)

## Open: bugs

### 7. BUG - MEDIUM: `apply_remote_status/2` is a read-modify-write

`connections.ex` `apply_remote_status/2` updates the row loaded earlier with no condition on its status. A peer request that loaded `active` can land after an admin revoked the row and set `suspended` over `revoked` with the `suspended_by_remote` marker; a second peer request (`active`) is then allowed to lift it, undoing the revocation of a receiver row.

**Resolution:** Not changed. Make the update conditional on the status the decision was based on (`update_all ... where status == ^from`), or lock the row (`FOR UPDATE`) and decide on the locked row; zero rows is `:status_change_not_allowed`.

### 8. BUG - MEDIUM: `register_incoming/2` logs and broadcasts inside its transaction

`create_connection` writes the activity row and broadcasts `{:connection_created, uuid}` before the advisory-lock transaction commits. An open page can reload before the commit and miss the pending registration; a failing activity insert poisons the transaction and loses the registration (the controller then gets a non-changeset error).

**Resolution:** Not changed. Return the row from the transaction and log/broadcast after it.

### 9. BUG - MEDIUM: the session code is logged when the sender URL has no host

`WebSocketClient` builds `wss://host?code=...`; `WebSockex.Conn.parse_url` answers `%URLError{url: url}` with the full URL for a URL typed without a scheme, and `receiver.ex` (about line 492) logs `inspect(reason)`. The code also goes into the query unencoded (a `&` in it adds parameters).

**Resolution:** Not changed. Check scheme and host before `start_link`, log the struct name only, `URI.encode_www_form/1` the code. The code-based flow has no production route.

### 10. BUG - MEDIUM: one non-map record aborts a remap pull

`check_record_keys` lets a non-map through; `Prepare.get_field/2` rescues `ArgumentError` only, so `BadMapError` reaches `guard_transfer` (`:import_failed`) with earlier rows already written and no counts recorded. The non-remap path counts such a record as an error.

**Resolution:** Not changed. `when is_map(record)` on the remap handlers with an error-count clause.

### 11. BUG - MEDIUM: a malformed primary key spoils a whole `DataImporter` batch

A key that stays text in a uuid column makes the batched `WHERE pk = ANY($1)` list unencodable. Either the call raises outside the per-record rescue, or `run_prefetch_query` returns `%{}` and `lookup_existing` answers a miss for every record, so existing rows hit unique violations instead of skip/overwrite/merge. (The failure mode was not run; either is batch-level.)

**Resolution:** Not changed. On a prefetch error fall back to per-record `find_existing`, or drop keys that did not prepare.

### 12. BUG - MEDIUM (partly pre-existing): status transitions have no precondition

`approve`/`suspend`/`revoke`/`reactivate_connection` apply from any status. A stale tab can reactivate a revoked row, leaving `revoked_at`/`revoked_reason` set on an active one.

**Resolution:** Not changed. Guard the source states, add an error atom with an `Errors.message/1` clause.

## Open: improvements

### 13. IMPROVEMENT - MEDIUM: REST answers with zero rows still take a download

`pull_data` and `table_records` call `settle_transfer(reservation, 0)`; the WebSocket path cancels. AGENTS.md says cancel when none were sent; `table-records` is documented as "one download per answer". Pick one.

### 14. IMPROVEMENT - MEDIUM: `inspect(reason)` goes to the untrusted peer

`sync_websock.ex` and `sync_channel.ex` reply `"Failed to ...: #{inspect(reason)}"`; a database error exposes constraint, table and column names. Map through `Errors.message/1` or a fixed text and log the detail.

### 15. IMPROVEMENT - MEDIUM: `SyncChannel` crashes on a non-binary `table`

`request:schema` and `request:count` have no `is_binary(table)` guard (`SyncWebsock` has). Only a host that mounts `SyncSocket` is exposed.

### 16. IMPROVEMENT - MEDIUM: a code-session WebSocket outlives its session

`SyncWebsock.authorize/2` is a no-op for `:session`; the store deletes the session when its owner dies, the socket keeps serving. Look the code up per message or have the store signal the socket. Only hosts that mount `Web.Sender`.

### 17. IMPROVEMENT - MEDIUM: `inspect/1` text stands in for a value in `DataExporter`

The last `serialize_value/1` clause sends Postgrex's `:NaN`/`:inf`/`:"-inf"` as text like `":NaN"`, against the "never let inspect text stand in for a value" rule, and unlike REST (Jason writes `"NaN"`). Send a defined form or the unsupported marker. Numeric NaN/Infinity does not round-trip on the HTTP import path either (`Prepare.parse_numeric_string`), where the WebSocket path handles it.

### 18. IMPROVEMENT - MEDIUM: `detect_changed_fields/2` over-reports

It compares form strings with typed struct values, so nearly every submitted field counts as changed; `changed_fields` in the audit row and the no-op-save guard are unreliable. Use `Map.keys(changeset.changes)`.

### 19. IMPROVEMENT - MEDIUM: `Errors.message/1` falls back to `inspect/1` for transport errors

`handle_*_http_result` passes `%Mint.TransportError{}`, `{:http_error, n}` and similar through, and `connections_live.ex` flashes them ("never `inspect(reason)` in a flash"). Map them to atoms at the notifier boundary. The same for `web/sender.ex` (flash with `inspect(reason)`, unrouted).

### 20. IMPROVEMENT - MEDIUM: History status badges and strategy are not translated

`history.ex` (about lines 417 and 559) calls `<.status_badge>` without `label=`; `@transfer.conflict_strategy` is shown raw. Use `status_label/1`.

### 21. IMPROVEMENT - MEDIUM: no overall deadline for an HTTP response

`request_capped` uses `receive_timeout` (idle time between chunks), so a sender dribbling bytes holds a pull for hours. Carry a start time in the `stream_while` accumulator and halt past a budget.

### 22. IMPROVEMENT - MEDIUM: peer text stored unbounded, and failure texts are English prose

`read_pull_page` stores the sender's error string verbatim in `transfers.error_message`, bounded only by the records cap, and other receiver failures are English sentences that `Errors.transfer_error/1` cannot translate. Cut peer text (about 500 bytes); store the classified atom name.

### 23. IMPROVEMENT - MEDIUM: WebSocket `response:tables` and `response:schema` are not shape-checked

Only `is_list(tables)` is checked; a non-map element raises in `Client.transfer_all` and `Receiver.Helpers`, a non-map schema in `normalize_schema_def`. The HTTP path validates both.

### 24. IMPROVEMENT - MEDIUM (pre-existing): Regenerate Token

`connections_live.ex` discards the new token, does not re-notify the peer (a sender row then gets 401 for good), and offers the button on receiver rows, whose token is the peer's pass to this site.

### 25. IMPROVEMENT - MEDIUM: refresh fan-out and retry of deterministic failures

`{:connection_created, _}` reloads without `skip_async`, so every open page requests every peer's status for each registration; the bulk retry re-pulls tables whose errors are unknown columns (up to 3 passes, each a download).

## Nitpicks (not changed)

- `Web.SyncWebsock.get_effective_limit/1` does not guard `max_records_per_request <= 0` (`ApiController.request_limit/1` does); `reserve_transfer` would raise.
- `api_controller.ex` `list-tables` SQL joins `pg_class` on the name alone (wrong `size_bytes` and duplicate rows across schemas) and its `NOT LIKE 'schema_%'`/`'pg_%'` treat `_` as a wildcard.
- A cut pull for a key whose cursor cannot be issued (numeric `NaN`, infinite date) answers `truncated` with neither `next_after` nor `unsupported_key_type`.
- `DataExporter.stream_records/2` ends silently on a mid-stream error.
- `AsyncTasks` falls back to `Task.start_link/1` when the supervisor is down, which ties the task to its caller; `SessionStore` uses `%{session | ...}` (a `KeyError` wipes every session); `ImportWorker.session_ref` is 32 bits of an unsalted hash of a 39-bit code.
- `Connections.find_by_token/1` ignores direction and `PhoenixKitSync.validate_incoming_password/1` is true when no password is set; neither has callers.
- `Connection.table_allowed?/2` and `requires_approval?/2` raise on a `nil` list; `normalize_site_url/1` keeps userinfo and query; the SSRF list omits 100.64.0.0/10; `site_url` changeset errors are not `gettext`; download passwords are unsalted SHA-256 (pre-existing).
- `Transfers.cancel/complete/fail/approve/deny` have no status guard (the approval workflow is unused).
- `history.ex` loads in `handle_params` unconditionally and raises on `?direction[]=x`; `index.ex` and `connections_live.ex` read in `mount`; "Close" mid-sync followed by a late `{:sync_table_complete, ...}` raises on `sync_progress == nil`; `String.to_existing_atom/1` and arbitrary strings from event params in `receiver.ex:235` and `connections_live.ex:566`; a peer's schema column `name`/`type` is rendered raw (a map-valued `type` kills the LiveView).
- `client.ex` accumulates every error with no cap and pages up to `Params.max_offset()` (1e9); `receiver.ex` ends a stalled table as complete with only a warning, where `Client` returns `:paging_stalled`.
