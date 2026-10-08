# GPT review of PR #26

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `77197a9`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## Result for the changed array path

The DB-backed array tests pass. Verified UUID, bytea, numeric, text, date, JSON/JSONB, multidimensional non-JSON arrays, domains over arrays, empty arrays, and NULLs. The element lookup joins the type's namespace, so a same-named type in another schema does not confuse it. Claude's schema-normalization fix creates arrays when their element type is provided.

The documented multidimensional JSON-array flattening behavior is retained; this review does not propose changing that contract.

## BUG - MEDIUM: HTTP Create Table still lacks the array element type

`ApiController.do_get_table_schema/1` selects `data_type` but omits `element_type`. A real HTTP schema request for a table with `refs uuid[]` therefore yields `ARRAY` without the type needed to create it. A temporary end-to-end schema probe confirmed that `fetch_table_schema/3` followed by `SchemaInspector.create_table/3` returns `{:error, :invalid_column_type}`.

**Resolution: open.** This is the HTTP gap acknowledged in Claude's review, not a failure of the WebSocket/channel array conversion this PR targets. A follow-up should expose the shared schema inspector's element metadata in HTTP schemas and test creation plus transfer through that protocol. HTTP row serialization/preparation also has separate type rules, so merely adding a field does not establish HTTP array round trips.

## Validation

Final normal suite: **848 tests, 0 failures**, including `array_values_round_trip_test.exs`, schema tests, and the first review's array-DDL test. `mix precommit` passed. The temporary HTTP schema probe intentionally demonstrated the remaining gap.
