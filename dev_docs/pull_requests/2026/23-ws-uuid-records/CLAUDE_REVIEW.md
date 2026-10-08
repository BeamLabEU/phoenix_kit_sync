# Claude review of PR #23: Fix uuid tables over WebSocket and channel, import values by column type

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

Clean of bugs. The column-type rules match what CLAUDE.md documents.

## 1. NITPICK: `data_importer.ex` `import_records/3`, `workers/import_worker.ex`

Failed records are now stored prepared, so a uuid PK in the log line is 16 raw bytes (`extract_record_pk` interpolates it) instead of its text. Debug log only.

**Resolution:** Not changed. Keep the wire record next to the prepared one if the log matters.

## 2. NITPICK: `data_importer.ex` `prepare_typed_value/2`

"By column type, never by value shape" does not hold for `USER-DEFINED` columns (citext, enums): a string such as `"2025-12-15"` still goes through the date/time sniffing, becomes a `Date`, and Postgrex cannot encode it. Pre-existing, narrow.

**Resolution:** Not changed. Add `"USER-DEFINED"` to the string-keeping clause if it turns up.

