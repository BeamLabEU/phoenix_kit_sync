# GPT review of PR #27 and second-review summary

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `5a37377`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## BUG - HIGH: Large UUID/text/composite-key tables have no bulk-pull continuation

Confirmed Claude's main open finding. The sender orders and limits `pull-data`, but accepts no cursor/offset. Both HTTP receiver paths issue one request. A repeated pull therefore returns the same prefix. Integer-key ranges can fetch later chunks manually; UUID/text IDs can be enumerated in small lists if already known, but provide no general bulk continuation. Composite keys cannot use precise filters at all.

**Resolution: open design decision.** Recommend a separate keyset-pagination change supporting every primary-key column, including composite keys, with the receiver looping while preserving its remap and counts. Raising/exposing the request limit is an administrative workaround for a known table size, not a complete large-table transfer mechanism. Retain the current failed/truncated status until a real continuation exists; reporting the prefix as complete would recreate silent data loss. No protocol redesign was added during this review.

## IMPROVEMENT - MEDIUM: Deterministically truncated pulls can still be retried

`process_table_sync_result/3` retains the truncation message but drops the boolean when building `table_results`. The retry selector checks only `errors > 0`. A cut table with failed rows, or children requiring parents outside the cut prefix, can therefore cause more requests for the same incomplete data and consume download allowances.

**Resolution: open.** Preserve truncation in progress metadata and exclude deterministic incomplete-prefix retries; make dependent-table handling explicit in the pagination follow-up. The retry logic is in `ConnectionsLive`, not `ConnectionNotifier`.

## Flag handling and history

The limit-plus-one query, whole-key ordering, additive flag, receiver failure status, and retained record counts pass the integration tests. Actual rows received before truncation remain imported, as documented. Older senders cannot signal truncation. Existing start-time/history-write issues from Claude's review remain follow-ups.

## Second-review summary for #18–#27

| PR | Result |
|---|---|
| [18](../18-composite-pk-pull/GPT_REVIEW.md) | Composite-key/progress changes verified; no additional scoped finding. |
| [19](../19-insert-record-identifiers/GPT_REVIEW.md) | **Fixed HIGH:** real session-token table excluded on both sides and all export protocols; explicit sender reads are denied. |
| [20](../20-remap-fixes/GPT_REVIEW.md) | **Fixed HIGH:** distinct text keys no longer collide during UUID normalization. HTTP numeric precision remains a medium follow-up. |
| [21](../21-precise-pull-filters/GPT_REVIEW.md) | **Fixed HIGH:** remap pulls honor and confirm filters instead of silently importing unrelated rows. |
| [22](../22-history-page-param/GPT_REVIEW.md) | Parameter bounds and merge resolutions verified. |
| [23](../23-ws-uuid-records/GPT_REVIEW.md) | Typed WebSocket/channel imports verified; date-shaped HTTP text remains a medium follow-up. |
| [24](../24-mint-advisories/GPT_REVIEW.md) | Lock-only Mint update verified; consumer-lock limitation recorded. |
| [25](../25-client-transfer-offset/GPT_REVIEW.md) | Paging tests pass; keyless/concurrent OFFSET stability remains a follow-up. |
| [26](../26-array-columns/GPT_REVIEW.md) | Array round trips and DDL tests pass; HTTP schema creation gap confirmed. |
| 27 | Truncation reporting verified; bulk continuation and deterministic retries remain open. |

## Validation

- Reviewed baseline `6449822`: **836 tests, 0 failures**, with Postgres integration enabled.
- New regressions demonstrated unintended imports, text-key FK corruption, and token-table exposure before fixes.
- Final repository `mix test`: **848 tests, 0 failures**, including integration tests.
- `mix precommit`: passed compile with warnings as errors, formatting, unused-lock check, Hex audit, strict Credo, and Dialyzer (existing ignore file retained).
- Three separate temporary HTTP/DB probes failed as expected for the documented remaining numeric, text, and array-schema gaps; they are not included in the passing suite count.

Claude's review files and pushed history were not edited. No release/version bump is part of this review.
