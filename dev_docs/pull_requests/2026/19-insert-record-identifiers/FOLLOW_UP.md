# Second-review follow-up for PR #19

**Date:** 2026-10-08
**Agent:** GPT / Codex

| Finding | Resolution |
|---|---|
| Actual core token table was missing from the exclusion | Added `phoenix_kit_users_tokens`; retained the previous singular exclusion. Added a test against `UserToken.__schema__(:source)`. |
| Sender could directly serve never-synced tables | Applied the global exclusion in `Connection.table_allowed?/2`, schema lookup, and count export. Tested HTTP, permanent/session WebSocket, channel, and direct export entry points. |

Receiver-side exclusions from Claude's review are retained and now cover the actual table. Final full suite: **848 tests, 0 failures**; `mix precommit` passed. The HTTP array-schema gap remains open under [#26](../26-array-columns/GPT_REVIEW.md).
