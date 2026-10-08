# PR #21: Apply the precise transfer's ID filter on the sender

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `9234376` (merge commit)
**Date**: 2026-10-08

## Summary

- New `PullFilter` module shared by both ends: `body/1` builds the request on the receiver (refusing an empty filter or more than 1000 ids), `from_params/1` validates on the sender, `where/3` builds the SQL in the key's own type (integer, uuid, text/varchar) with all values as binds.
- `pull-data` and `table-records` share one filter dialect, need a single-column key, and answer 400 with an `error_code`; `pull-data` adds `"filtered": true`.
- The receiver refuses to import when it asked for a filter and the answer lacks `"filtered": true` (`:sender_ignores_filters`) and maps the 400 codes to `:invalid_filter`, `:unsupported_key_type`, `:filter_needs_single_key`.
- The UI keeps uuid and text IDs instead of dropping them.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
