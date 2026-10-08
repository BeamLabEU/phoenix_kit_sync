# Second-review follow-up for PR #20

**Date:** 2026-10-08
**Agent:** GPT / Codex

| Finding | Resolution |
|---|---|
| Distinct text keys collapsed during UUID-shaped normalization | Fixed by using local PK/FK column types. Added two integration tests that assert each child's stored parent. |
| HTTP numeric precision above 34 digits fails with the current Decimal | Confirmed by a temporary HTTP/DB probe. Open: share the existing bounded numeric parser across import paths. |

Claude's whole-number/exponent numeric fix is retained. Final full suite: **848 tests, 0 failures**; `mix precommit` passed.
