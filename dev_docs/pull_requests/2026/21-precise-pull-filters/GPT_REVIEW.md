# GPT review of PR #21

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `9234376`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## 1. BUG - HIGH: Remap pulls silently ignore filters and import the whole answer

`pull_table_data_with_remap/4` is documented as the remap-aware equivalent of `pull_table_data/3`, but did not validate or send `:ids` / `:id_range`, or require the sender's `filtered: true` confirmation. Calling it with `ids: [2]`, or even `ids: []`, imported all four stub rows. With overwrite or merge, unrelated local rows can be changed. The current bulk LiveView caller does not pass a filter, but the public library function accepts options and must honor their meaning.

This was listed as a nitpick in Claude's review. The reproduced unintended database writes warrant a bug finding.

**Resolution: fixed.** The remap pull uses the same `PullFilter.body/1`, request fields, confirmation check, and 400 error-code handling as the ordinary pull. An invalid filter is rejected before transfer creation or HTTP work. An ignored filter fails the transfer before import and returns the unchanged remap.

**Evidence:** three added integration cases reproduce ignored request fields, all-row import on an unconfirmed answer, and all-row import on an empty ID list. All now pass.

## Other checks

Claude's zero-padded-ID fix holds: `007`, `+5`, and `-0` remain strings; canonical whole integers remain integers. Filter binds are parameterized and typed in the key's own type, and authorization occurs before the filter query. Composite-key filtering is rejected explicitly. The preview maps known sender filter errors correctly.

**NITPICK, open:** a preview from an older sender can still show unfiltered rows, because `table-records` has no filter-confirmation field. The import path is protected; no database write follows from the preview itself.

## Validation

Final `mix test`: **848 tests, 0 failures**, including integration tests. `mix precommit` passed. See [FOLLOW_UP.md](FOLLOW_UP.md).
