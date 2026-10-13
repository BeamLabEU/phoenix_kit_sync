# Follow-up for PR #26: array columns over WebSocket and channel

Reviews: `CLAUDE_REVIEW.md` (one finding, fixed in the review), `GPT_REVIEW.md`
(one bug with two parts). Each was re-read against the current code by reading
it.

## Fixed (pre-existing)

- ~~**Claude #1** `create_table/3` wrote `"tags" ARRAY NOT NULL`~~. Still in
  place: `lib/phoenix_kit_sync/schema_inspector.ex:436-437` spells an array
  column `<element>[]` when `element_type` is present, and a bare `ARRAY` is
  refused as `:invalid_column_type` (`:333`).

## Fixed (Batch 1 — 2026-10-13)

- ~~**GPT, BUG - MEDIUM (schema part)** HTTP `table-schema` sent no element
  type~~. `lib/phoenix_kit_sync/web/api_controller.ex:1407-1421`:
  `schema_column/1` answers `"element_type"` beside `"type"`. Tests in
  `test/integration/http_table_schema_test.exs`: the answer carries
  `"element_type" => "uuid"` for a `uuid[]` column (`:120`), and a table with
  `text[]`, `uuid[]`, `integer[]` and `varchar(20)[]` columns is created from
  the schema the API sends (`:64`).

## Fixed (Batch 2 — 2026-10-13)

- ~~**GPT, BUG - MEDIUM (transfer part)** Array rows over HTTP had no element
  handling on either side~~. Probed first, with a real table read through
  `pull-data` and written back by a real pull: a `uuid[]` or `bytea[]` with
  any non-UTF-8 element failed the whole answer (500, `Jason.EncodeError`);
  `numeric[]`, `date[]`, `time[]`, `timestamp[]` and `timestamptz[]` left the
  sender but failed their record on import; a `jsonb[]` of JSON arrays came
  back two-dimensional; `text[]`, `varchar[]`, the integer, float and boolean
  arrays and a scalar `jsonb` were already right. Now one implementation per
  direction serves both protocols: `ApiController.serialize_rows/3`
  (`lib/phoenix_kit_sync/web/api_controller.ex:1334-1346`, for `pull-data`
  and `table-records`) calls `DataExporter.serialize_array/2`
  (`lib/phoenix_kit_sync/data_exporter.ex:178`) by the column's
  `element_type` (`table_key/1`, `:1203-1222`); `Prepare.value/4` and
  `key_value/2`
  (`lib/phoenix_kit_sync/connection_notifier/prepare.ex:72`, `:99`)
  call `DataImporter.prepare_array/2`
  (`lib/phoenix_kit_sync/data_importer.ex:385-391`) for a column the target
  names `{:array, element_type}`
  (`lib/phoenix_kit_sync/connection_notifier.ex:2137`). Test:
  `test/integration/http_array_values_test.exs` crosses seventeen element
  types with eight shapes (values, one value, a NULL element, only NULLs,
  empty, NULL, two dimensions, two dimensions with a NULL), plus `jsonb[]`,
  a scalar `jsonb` holding lists, `table-records`, and an unreadable element
  failing its own record only.
- ~~**From the review of the sweep, not of this PR: struct-valued column
  types**~~. An `interval`, `inet`, `cidr` or `macaddr` value reached
  `inspect/1` on the WebSocket path and failed the whole answer on REST
  (Jason has no encoder for the Postgrex structs).
  `PhoenixKitSync.ExtensionTypes` (`lib/phoenix_kit_sync/extension_types.ex`) writes
  those four as text and reads them back by column type on both paths, and
  marks every other struct (ranges, geometric types, `tsvector`) so the
  importer fails that record with the type named. Test:
  `test/integration/extension_types_round_trip_test.exs`; the four types are
  in the array table above as well.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_sync/web/api_controller.ex` | 1, 2 | `table-schema` with `element_type`; array columns serialized by element type; structs through `ExtensionTypes` |
| `lib/phoenix_kit_sync/data_exporter.ex` | 2 | `serialize_array/2` public; structs through `ExtensionTypes` |
| `lib/phoenix_kit_sync/data_importer.ex` | 2 | `prepare_array/2` public; extension types read, marker refused |
| `lib/phoenix_kit_sync/connection_notifier/prepare.ex`, `connection_notifier.ex` | 2 | array columns and extension types read by type |
| `lib/phoenix_kit_sync/extension_types.ex` | 2 | new |
| `test/integration/http_table_schema_test.exs` | 1 | new: schema answer and Create Table over HTTP |
| `test/integration/http_array_values_test.exs` | 2 | new: element type × shape through both real ends |
| `test/integration/extension_types_round_trip_test.exs` | 2 | new |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

- A JSON `null` element of a `jsonb[]` comes back as a NULL element, and a
  multi-dimensional `jsonb[]` as one dimension, on every path: Postgrex
  decodes both nulls as `nil` and reads a nested list as a dimension
  (`lib/phoenix_kit_sync/data_importer.ex:435`). Not a finding of either
  review; recorded because the probe showed it.
- Ranges, multiranges, the geometric types and `tsvector` are not carried
  (`lib/phoenix_kit_sync/extension_types.ex:57`): a record holding one fails on
  import. An infinite `interval` is not handled either.
