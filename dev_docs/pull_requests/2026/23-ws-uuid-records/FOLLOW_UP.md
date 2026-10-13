# Follow-up for PR #23: uuid tables over WebSocket and channel, values by column type

Reviews: `CLAUDE_REVIEW.md` (two nitpicks), `GPT_REVIEW.md` (one bug, and the
second nitpick repeated). Each was re-read against the current code by
reading it. The HTTP numeric-precision item GPT mentions is recorded under
PR #20 and is not triaged here.

## Fixed (pre-existing)

None.

## Fixed (Batch 1 — 2026-10-13)

- ~~**Claude #1** A failed record's uuid key was logged as 16 raw bytes~~.
  `lib/phoenix_kit_sync/workers/import_worker.ex:133`: a 16-byte key is
  printed through `Ecto.UUID.load!/1`, any other binary through `inspect/1`.
- ~~**Claude #2 / GPT** A string in a `USER-DEFINED` column (citext, enum)
  went through the date/time sniffing~~.
  `lib/phoenix_kit_sync/data_importer.ex:512`: a string in any column the
  schema names whose type is not a date/time type is bound as it came.
- ~~**GPT, BUG - MEDIUM** HTTP pulls cast date-shaped text~~.
  `lib/phoenix_kit_sync/connection_notifier/prepare.ex:80`: `value/4`
  parses a string as a date, time or number only when the target column's
  type is one (`typed_string/3`, `:104-116`). The HTTP insert path calls it
  with the target's column types (`lib/phoenix_kit_sync/connection_notifier.ex:2242`);
  key lookups use `key_value/2` (`:2038`, `:2095`). Covered by
  `test/integration/pull_value_shapes_test.exs:111`.

On both paths a column the type map does not name still falls through to the
shape rules (`prepare.ex:83`, `data_importer.ex:516`).

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_sync/workers/import_worker.ex` | key text in the failed-record log |
| `lib/phoenix_kit_sync/data_importer.ex` | string kept in every non-temporal named column |
| `lib/phoenix_kit_sync/connection_notifier/prepare.ex` | `value/4`, `key_value/2` by column type |
| `lib/phoenix_kit_sync/connection_notifier.ex` | HTTP import and lookups call them |
| `test/integration/pull_value_shapes_test.exs` | column types crossed with value shapes |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

None.
