# Claude review of PR #26: Fix array columns over WebSocket and channel

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

No bugs in the encode/decode paths.

## 1. IMPROVEMENT - MEDIUM: `schema_inspector.ex` `normalize_column/2`, `create_table/3`

`get_schema` now reports `type: "ARRAY"` plus `element_type`, but `normalize_column/2` dropped `element_type` and `map_column_type/1` had no `"ARRAY"` clause, so the DDL read `"tags" ARRAY NOT NULL`, invalid SQL that `valid_column_type?("ARRAY")` accepted. A receiver without the table could not create it, so the array import fix was unreachable in that flow.

**Resolution:** Fixed. `column_type/1` spells an array column `<element>[]` when `element_type` is present; a bare `ARRAY` is refused as `:invalid_column_type`. `USER-DEFINED` elements fail the type regex and are refused the same way. Over HTTP, `table-schema` still sends no element type, so Create Table there refuses array columns with a clear error. Test in `sender_identifiers_test.exs` (integration, not run here).

