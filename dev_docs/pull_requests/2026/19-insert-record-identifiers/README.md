# PR #19: Validate and quote SQL identifiers from the sender; make Create Table work over HTTP

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `3129e7c` (merge commit)
**Date**: 2026-10-08

## Summary

- `valid_identifier?/1` gains `\A..\z` anchors and a 63-byte cap.
- The pull refuses an invalid table name or record key before writing, and inserts only columns the local table has (`unknown_columns` counts as errors).
- `create_table/3` validates every column name, PK column and type (`valid_column_type?/1`); `ApiController` quotes every table, PK and ORDER BY identifier and `table-schema` sends `primary_key`.
- Create Table refuses a schema with no primary key; failure flashes go through `Errors.message/1`.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
