# Claude review of PR #19: Validate and quote SQL identifiers from the sender; make Create Table work over HTTP

**Reviewer**: Claude (read-only pass over the PR's own diff and the current
state of the code it touches; the DB-backed tests were not run, there is no
database in the review environment).

The identifier guards, the type regex, the `@type_words` filter and the quoting in `ApiController` hold: a second free word such as `DEFAULT` or `REFERENCES` is refused, and `complete_pull_transfer` runs `check_record_keys` before any write.

## 1. IMPROVEMENT - MEDIUM: `connection_notifier.ex` `check_table_name/1`, `data_importer.ex` `import_records/3`

The receiver-side pull checked only `valid_identifier?` and that the table exists. `SchemaInspector.excluded_table?/2` was private and used only for listing, so a sender that lists `phoenix_kit_user_tokens` or `schema_migrations` could have the admin pull it with `overwrite`, against the rule that those are never synced. This matters because the PR's own threat model is a hostile sender.

**Resolution:** Fixed. `SchemaInspector.excluded_table?/1` is public; both pull paths return `{:error, :table_excluded}` (new `Errors` clause) and `DataImporter.import_records/3` refuses the same tables, which covers the WebSocket/channel/Oban path. Tests: `excluded_tables_test.exs`, `data_importer_test.exs`.

## 2. IMPROVEMENT - MEDIUM: `connections_live.ex` `sync_error_message/1`

A hand-kept allowlist of atoms; anything else, `:invalid_response` and `:unexpected_response` included, rendered as `Sync failed: ":invalid_response"` although `Errors` has a clause for each.

**Resolution:** Fixed. Any atom now goes through `Errors.message/1`.

## 3. IMPROVEMENT - MEDIUM: `api_controller.ex` `records_clause/2`

`table-records` ordered by the first PK column only. On a composite key the order is not total, so OFFSET pages can repeat or skip rows; a table with no key fell back to `ORDER BY "id"`, which errors when there is no such column. `pull-data` already orders by every key column.

**Resolution:** Fixed. The unfiltered page reuses `key_order/1`; the unused `resolve_pk_column/1` is gone.

## 4. NITPICK: `api_controller.ex` `table-schema`, `schema_inspector.ex` `column_type/1`

Create Table failed with a raw Postgres error for array columns (`table-schema` sends `data_type` "ARRAY" and no element type, so the DDL read `"col" ARRAY`), and a `character(n)` column is created as `char(1)` because `max_length` is applied only to `character varying`.

**Resolution:** Partly fixed. A bare `ARRAY` is now refused as `:invalid_column_type`, and a schema that carries `element_type` (the WebSocket/channel one) creates `<element>[]` (see #26). Over HTTP `table-schema` still sends no element type. `character(n)` is not changed: record it if a table with one turns up.

## 5. NITPICK: `schema_inspector.ex` `check_create_columns/2`

A sender whose `primary_key` names a column that is not in `columns` passes validation and fails in Postgres; the flash is `inspect/1` of the exception.

**Resolution:** Not changed. Cosmetic: the table is not created either way.

