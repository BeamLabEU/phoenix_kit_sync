# PR #27: Mark pull-data answers cut at max_records_per_request and fail those pulls

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `5a37377` (merge commit)
**Date**: 2026-10-08

## Summary

- `pull-data` used to cut an answer at `max_records_per_request` and call it a success, so a table over the limit looked fully synced.
- The sender fetches `limit + 1` rows in primary-key order and adds `"truncated": true` when rows were left over (only ever added, never sent as false) and records its own send as `failed`.
- The receiver (`ConnectionNotifier.finish_pull_transfer/4`) imports the rows that came but fails the transfer with the counts; the result carries `truncated: true` and the LiveView shows a per-table error line. `Errors.message(:truncated)`; `Transfer.fail_changeset/3` and `Transfers.fail_transfer/3` take `stats`.
- An older sender cannot send the flag, so its cut answers still read as whole.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
