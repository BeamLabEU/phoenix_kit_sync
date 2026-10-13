# GPT review of PR #28 and the pre-publication follow-up

**Date:** 2026-10-13

**Baseline:** `8cc9c46` on main, including merged PRs #28–#32.

**Scope:** Claude's changes and outstanding findings, the authorization, registration, import and socket paths affected by the quality sweep, the later four PR diffs, and the complete PostgreSQL-backed suite. Claude's review files are preserved.

## Fixed findings

| Severity | Trigger and consequence | Resolution |
| --- | --- | --- |
| BUG - HIGH | A remote request uses an old active receiver snapshot after an admin revokes it; the peer can suspend, then reactivate that row. Checking status alone also misses a local takeover of a remote suspension. | Local and remote status operations reload the row under the same `FOR UPDATE` lock and decide using its current status and metadata. Audit and broadcasts happen after commit. |
| BUG - HIGH | A stale admin tab approves or reactivates a revoked connection. A generic settings update can also bypass the status functions. | Source-state preconditions protect local actions. Status changes through settings use the original status as an update filter and refuse reopening revoked/expired rows. |
| BUG - MEDIUM | Registration publishes its event before commit, and a best-effort activity insert can abort its transaction. | Registration performs only its guarded insert inside the advisory-lock transaction; logging and PubSub happen afterwards. A telemetry regression asserts that the activity insert runs outside the explicit transaction. |
| BUG - MEDIUM | One non-map record or an exception during FK preparation aborts the remap pull after earlier writes, losing its counts. | Each remap record is isolated. Unreadable rows increment the error count, later rows continue, and History records the counts. |
| BUG - MEDIUM | One malformed UUID spoils batched conflict lookup; an unsuccessful prefetch is interpreted as proof that every row is absent. | An unavailable prefetch has a separate sentinel and falls back to individual lookups. Tests cover skip, overwrite and merge with mixed valid/invalid keys. |
| BUG - MEDIUM | Repeated primary keys in one batch use the lookup snapshot from before the first write. Later rows hit unique violations or merge against stale data. | Repeated keys use current per-record lookups, preserving all three conflict strategies. This is an additional finding beyond Claude's list. |
| BUG - HIGH | A connected session socket keeps reading after its owner/page disappears. | Both socket implementations check the live send session before requests. The WebSock handler also refuses joins after removal. Tests cover both implementations after session deletion. |
| BUG - MEDIUM | A sender URL without a scheme can put the session code into a WebSockex URL error; a query delimiter in the code changes its meaning. | Validate URL scheme/host, encode query values, replace existing code/version parameters, and return classified connection errors. A real socket test uses a code containing query delimiters. |
| BUG - HIGH | Driver errors and Ecto debug logs can expose credentials or synced record values. Shortening error text still exposes its prefix. | Suppress credential/record query logs, redact credential schema fields, and log only exception classes or failed-record counts. Also remove raw socket error/decode payloads from logs. Debug-level tests exercise real writes, lookups and a failing import. |
| BUG - MEDIUM | A peer sends non-text table/schema fields or malformed channel table parameters, crashing consumers. | `PeerData` validates schema fields and normalizes socket table metadata; HTTP schemas use the same check. Channel schema/count handlers guard table/ref types. Requests fail as `invalid_response` instead of forwarding malformed data. |
| BUG - MEDIUM | WebSocket export substitutes inspected tuple/bit values for real values, and special numeric values do not round-trip consistently. | Tuple/bit values use the unsupported marker on both paths. NaN and infinities have explicit text forms and typed imports. PostgreSQL round-trip tests exercise numeric, real and double precision values. |
| BUG - MEDIUM | A late completion or queued next table reaches a closed or newly opened sync, crashing progress updates or acting on the new run. | Queued work and replies carry a run reference. Closing clears the run; old work/results are ignored while already-running imports finish and write History. |
| BUG - MEDIUM | Regenerate Token discards the returned credential and never updates the peer; receiver-side rotation changes a credential owned by the sender. | Remove the unsafe UI action and refuse events from older tabs with reconnect instructions. The low-level API remains available for callers that coordinate both sites, documented in README. Seamless rotation needs a protocol change. |
| IMPROVEMENT - MEDIUM | An empty REST answer consumes a download despite sending no rows. | Cancel empty reservations, matching the socket and AGENTS.md. Test both row-returning REST actions. |
| IMPROVEMENT - MEDIUM | Raw database exceptions are sent to socket peers. | Socket replies use translated atom messages, with a generic message for structured errors. |
| IMPROVEMENT - MEDIUM | Matching form strings are compared directly with typed schema values, generating false update events/audit rows. | Derive changed fields from the cast changeset and exclude virtual credential fields. A typed no-op save has no new activity. |
| IMPROVEMENT - MEDIUM | A sender that keeps dribbling chunks evades the per-chunk HTTP timeout. | Pass Finch's complete-response `request_timeout` alongside `receive_timeout`. A real TCP peer proves that ongoing chunks still time out. |
| IMPROVEMENT - MEDIUM | Pull failures persist peer-controlled text or English prose, making History unbounded/untranslatable. | Store classified atom names and a bounded key-type form, and translate them through `Errors.transfer_error/1`. Older stored text remains readable. Table-fetch transport failures are classified at their boundary too. |
| BUG - MEDIUM | Delete notifies the peer before the local delete commits. | Send its best-effort notification only from the successful local-delete branch. |

Claude's six fixes were retained and tested. Tuple/bit markers now have real export/import coverage; malformed socket errors have boundary tests. His log changes were strengthened as described above.

## Test environment correction

The baseline ran **2,077 tests with 10 failures**. Current core can emit prefixless admin URLs, while the test router mounted only `/en/admin/*`. The test router now mirrors both admin scopes in one live session, and navigation assertions use core's path helper. LiveView links explicitly pass their current locale. The initial failures were not evidence that prefixless production routes were absent.

## Remaining work and deliberate limits

- **IMPROVEMENT - MEDIUM:** History still relies on core's default badge labels and renders the conflict strategy directly. Its translated badge support depends on the core-version consideration already recorded in AGENTS.md. No core dependency floor was changed here.
- **IMPROVEMENT - MEDIUM:** Registration broadcasts can still trigger status refreshes for existing active peers on every open Connections page. Deterministic per-record import failures can still be retried by the bulk UI. These need separate refresh/retry policies; they are not authorization bypasses.
- **NITPICK:** `list-tables` still joins `pg_class` by name alone and uses wildcard underscores in its name filters. Cross-schema size/count presentation deserves a separate cleanup.
- A failed stream read still ends `DataExporter.stream_records/2` silently. The code-based receiver's stalled-page presentation and some unrouted Sender/Receiver error/template behavior remain as recorded by Claude. Client frame-size limits need a different WebSocket client, as AGENTS.md states.
- Empty/non-finite key positions can still lack a useful unsupported-key-type diagnostic, although the receiver marks the transfer truncated. Auto-created table defaults, sequences and modifiers remain deliberately incomplete.
- Lower-level token rotation is local only. No new peer credential-rotation protocol, automatic scheduler, approval/rate-limit layer, webhook retries, snapshots or other deliberate non-feature was added.

## Validation

- `mix test`: **2,156 tests, 0 failures**, with PostgreSQL-backed integration tests enabled.
- The new published Decimal requirement has a separate dependency-floor test; see [PR #30](../30-decimal-advisory/GPT_REVIEW.md).
- `mix precommit`: compile with warnings as errors, formatting, unused-lock check, Hex audit, strict Credo and Dialyzer. The full alias passed; existing Dialyzer exclusions were unchanged.
- Gettext extracted/merged, changed Estonian/Russian messages filled, fuzzy flags cleared, and msgstr changes reviewed.
- Version remains `0.2.4`. This review does not push, publish, tag or bump a release.
