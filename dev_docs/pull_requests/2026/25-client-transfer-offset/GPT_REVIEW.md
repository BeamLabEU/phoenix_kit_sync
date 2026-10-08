# GPT review of PR #25

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `54549b6`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## Result

No additional regression in the changed paging loops. Both consumers advance by the actual records received and stop on an empty page. The Receiver retains its own outstanding offset, and the Client ignores a false `has_more` hint. Actual DB/WebSocket tests verify each source row is updated exactly once for oversized batches, exact last pages, low permanent-connection caps, and a sender that always says there are no more rows.

## IMPROVEMENT - MEDIUM: OFFSET paging has no snapshot guarantee

The no-skip result holds for an unchanged source with a total key order. Keyless tables have no `ORDER BY`; even keyed OFFSET pages can move when concurrent inserts/deletes change the rows before the offset. This is pre-existing, not a regression in advancing by received length.

**Resolution: open.** A `ctid` fallback does not provide a general concurrency guarantee. Refuse keyless transfers or establish an explicit stable-read policy; use keyset paging where supported if concurrent changes must be tolerated. No snapshot/versioning feature was added, in keeping with repository scope.

The batch-index logging and misbehaving-peer loop concerns in Claude's review remain unchanged. Upgrade receivers before relying on small sender caps; old receivers still advance by their requested batch size.

## Validation

`client_transfer_test.exs` and `receiver_paging_test.exs` passed with the full **848 tests, 0 failures**, including integration tests. `mix precommit` passed.
