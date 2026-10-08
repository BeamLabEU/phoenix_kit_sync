# PR #18: Fix pulls of composite-key tables and stuck sync progress

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `f2de3c6` (merge commit)
**Date**: 2026-10-08

## Summary

- `ConnectionNotifier` carries the local table's primary-key columns through a pull. Overwrite uses `ON CONFLICT (a, b)` over the whole key and append no longer strips a composite key.
- A table that is missing locally or has no primary key is refused before the sender's limits are spent (`:table_missing_locally`, `:no_primary_key`).
- `guard_transfer`/`guard_pull` turn a raise or exit into a failed transfer plus a result for the LiveView (`:import_failed`, `:pull_failed`), so progress no longer sticks on "syncing".
- A non-string remote `error` no longer crashes the handler (`:invalid_response`); `sort_by_dependencies` no longer lists a self-referencing or cyclic table twice; the results table shows a per-table error line.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
