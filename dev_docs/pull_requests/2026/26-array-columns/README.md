# PR #26: Fix array columns over WebSocket and channel

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `77197a9` (merge commit)
**Date**: 2026-10-08

## Summary

- `ColumnInfo` gains `element_type`; `SchemaInspector.get_schema` fills it with a `pg_type` lookup from `udt_name`, so a domain over an array counts, and non-`pg_catalog` elements report `USER-DEFINED`.
- The exporter serialises array elements by element type at every depth; the importer maps `"ARRAY"` to `{:array, elem}` and reads elements recursively.
- `json`/`jsonb` arrays pass JSON-array elements as `Jason.Fragment`, so a multi-dimensional `jsonb[]` comes back one-dimensional (documented in CLAUDE.md).
- New `array_values_round_trip_test` and `schema_inspector_test` cases.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
