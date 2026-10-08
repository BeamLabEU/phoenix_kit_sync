# GPT review of PR #19

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `3129e7c`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## 1. BUG - HIGH: The exclusion names the wrong session-token table

`SchemaInspector.@excluded_tables` and the first review's new tests name `phoenix_kit_user_tokens`. Core's `PhoenixKit.Users.Auth.UserToken.__schema__(:source)` is **`phoenix_kit_users_tokens`**, which exists in the test database. Thus the receiver exclusion added in `6449822` did not protect the real token table. These tokens include unhashed session-token bytes, as confirmed in core's `UserToken.build_session_token/2`.

The HTTP sender also applied only a connection's configurable lists. With the default empty lists, `list-tables` exposed internal tables and a direct `pull-data` request for `phoenix_kit_users_tokens` returned **200**. Hiding a table from the offered list would not protect direct requests. This is a pre-existing exposure missed by the first review, rather than an injection introduced by this PR.

**Resolution: fixed.** Added the actual table name while retaining the previous exclusion entry. `Connection.table_allowed?/2` now enforces the global exclusion even if a connection explicitly allowlists that table. `SchemaInspector.get_schema/2` and `DataExporter.get_count/2` reject excluded tables before querying; the schema guard also covers record and stream exports, including ephemeral WebSocket/channel requests. Both receiver pull APIs and `DataImporter` inherit the corrected name. Updated `AGENTS.md` to identify the actual core table.

**Evidence:** the API regression returned 200 before the fix and 403 afterward. Added REST list/read tests, session and permanent WebSocket tests, a channel test, and a pure test against core's actual schema source, rather than merely repeating the exclusion's spelling. Existing import-exclusion coverage now includes the real table.

## Identifier and DDL checks

The identifier length/anchor checks, validated DDL type syntax, quoted primary keys, and sender-side SQL quoting hold. Sender record keys are checked before any HTTP import writes, and unknown local columns fail the affected record. Quoting also preserves mixed-case table authorization.

The remaining HTTP array-schema limitation is recorded under [#26](../26-array-columns/GPT_REVIEW.md). The `character(n)` length and nonexistent primary-key-column issues from Claude's review remain follow-ups; no additional fix was applied for them.

## Validation

Baseline main: **836 tests, 0 failures**. Final `mix test`: **848 tests, 0 failures**, including integration tests. `mix precommit` passed. The new regressions failed on the reviewed main before the fix. See [FOLLOW_UP.md](FOLLOW_UP.md).
