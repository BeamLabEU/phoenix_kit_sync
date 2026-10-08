# PR #22: Fix crashes on bad page, offset and limit values

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `eefc6d9` (merge commit)
**Date**: 2026-10-08

## Summary

- New `PhoenixKitSync.Params` (`bounded_int/4`, `page/2`, `max_offset/0`).
- History no longer crashes on `?page=abc`, `0`, negative or huge values and clamps a page past the end.
- The `table-records` API (limit 1..100, offset 0..1e9), the WebSocket handler and the channel handler fall back to defaults or clamp instead of failing in the query; their limits are capped at `DataExporter.max_limit/0`.
- `Validators.valid_table_name?` delegates to `SchemaInspector.valid_identifier?/1`; `ConnectionsLive.format_bytes` is public and total.

Merged with conflicts against `main`, resolved by the reviewer: `validators.ex` keeps this PR's bounded limit/offset and drops `ids`/`id_start`/`id_end` from `validate_records` (`main` had moved them to `PullFilter.from_params/1`); `receiver.ex` keeps both aliases; the two test files keep the tests from both sides.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
