# GPT review of PR #23

**Reviewer:** GPT / Codex (OpenAI)
**Date:** 2026-10-08
**PR merge:** `72d6c44`
**Reviewed main:** `6449822`, including Claude's follow-up fixes

## Result for the changed WebSocket/channel path

No additional regression found in typed UUID, bytea, JSON, text, or numeric round trips. Ran the DB-backed tests that were unavailable to Claude, including high-precision and boundary numeric values, repeated UUID imports, binary wrappers, and real WebSocket/channel serialization. These paths preserve column types as documented.

The exclusion fix from the first review missed core's actual token-table name. That security finding and the cross-protocol fix are recorded under [#19](../19-insert-record-identifiers/GPT_REVIEW.md).

## BUG - MEDIUM: Equivalent HTTP pulls still cast date-shaped text

The HTTP path uses `ConnectionNotifier.Prepare.value/3`, which calls date/time parsers before consulting its numeric-column map. A text value `2026-01-01` becomes a `Date`; Postgrex then refuses to bind it to text. A temporary HTTP/DB probe returned `imported: 0, errors: 1`. Date-shaped text works through the typed `DataImporter` path this PR changes.

**Resolution: open, pre-existing HTTP behavior.** Consolidate HTTP value preparation and PK/unique matching around actual column metadata, reusing the typed rules rather than adding isolated shape exceptions. The HTTP numeric precision failure is recorded under [#20](../20-remap-fixes/GPT_REVIEW.md).

User-defined scalar types still fall through the generic shape parsers in `DataImporter`; this narrow limitation from Claude's review remains open. Built-in string types are covered by the passing round-trip tests.

## Validation

Final normal suite: **848 tests, 0 failures**, including integration tests; `mix precommit` passed. The temporary HTTP probe demonstrated a remaining limitation and is outside that passing suite.
