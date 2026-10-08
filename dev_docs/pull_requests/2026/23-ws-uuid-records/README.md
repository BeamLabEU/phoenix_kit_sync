# PR #23: Fix uuid tables over WebSocket and channel, import values by column type

**Author**: @timujinne
**Reviewer**: Claude
**Status**: Merged
**Commit**: `72d6c44` (merge commit)
**Date**: 2026-10-08

## Summary

- `DataExporter` handed Postgrex's raw 16-byte uuids and other non-UTF-8 bytes to the WS/channel JSON encoder, which raised, so no table with a UUIDv7 key could be read over those paths. It now writes a `uuid` column as canonical text and non-UTF-8 bytes as `%{"__phoenix_kit_binary__" => base64}`, like the HTTP API.
- `DataImporter.import_records/3` prepares all records once by the target column's type from the loaded schema: the wrapper becomes bytes only in `bytea`/`uuid` columns, uuid text becomes bytes only in `uuid`, `numeric` strings become `Decimal` (bounded digits and scale), `text` and `bytea` text stay, `json`/`jsonb` pass through as terms.
- New `binary_values_round_trip_test` plus WS and channel reply tests.

## Related

All PRs #18 to #27 were merged the same day; see the sibling folders under
`dev_docs/pull_requests/2026/`.
