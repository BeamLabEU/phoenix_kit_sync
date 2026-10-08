# GPT review of PR #20

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `fa7a03d`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## 1. BUG - HIGH: UUID canonicalization corrupts distinct text-key remaps

`remap_key/1` called `Ecto.UUID.cast/1` on every binary, regardless of its column type. That API accepts any 16-byte binary and normalizes the case of UUID text. Consequently, distinct **text** keys `AAAAAAAAAAAAAAAA` and `41414141-4141-4141-4141-414141414141` collapse into the same remap key. Uppercase and lowercase UUID-shaped text keys also collapse, although Postgres text keys distinguish them.

When both parents match existing local rows by their unique names, the second mapping overwrites the first. Both children then import successfully with the second parent's FK. This is silent relational data corruption, not just a failed record.

**Resolution: fixed.** Cache local column types with the existing target metadata and pass the PK/FK type into remap-key construction. Canonicalize only `uuid` columns; text keys retain their exact bytes and case. Integer remaps retain their existing string keys, and UUID remaps continue to accept wrapped/raw/canonical forms.

**Evidence:** two added integration cases failed before the fix with `[["child-a", "local-b"], ["child-b", "local-b"]]`; both now store the intended distinct parents. Existing UUID, uppercase UUID FK, integer, chained-remap, key-as-FK, overwrite, and merge tests continue to pass.

## 2. BUG - MEDIUM: HTTP numeric preparation still rejects more than 34 significant digits

Claude's whole-number/exponent fix works for ordinary values. However, `Prepare.new_decimal/1` uses `Decimal.new/1`, which has the default 34-significant-digit parsing bound in the currently resolved Decimal 3.1.1. A valid PostgreSQL numeric such as `123456789012345678901234567890.123456789` is rescued back to an unchanged string; Postgrex then rejects it. A temporary DB-backed HTTP pull probe confirmed `imported: 0, errors: 1` for that value.

**Resolution: open.** The WebSocket importer already has a bounded parser for this case, introduced in #23. A follow-up should share that parser with HTTP preparation and matching rather than introduce another independently maintained numeric parser. This limitation is in current main; its manifestation also depends on the resolved Decimal version.

## Validation

Final committed-suite validation: **848 tests, 0 failures**, including integration tests; `mix precommit` passed. The separate temporary numeric probe intentionally demonstrated the remaining failure and is not part of the passing suite. See [FOLLOW_UP.md](FOLLOW_UP.md).
