# Resolution of the pre-publication review

2026-10-13, baseline `8cc9c46`. See [GPT_REVIEW.md](GPT_REVIEW.md) for implementation and validation details. Claude's original file is unchanged.

| Claude finding | Disposition |
| --- | --- |
| 1–6: strategy, serialization, non-text status/error, credential prefixes and record logs | Retained; regression coverage added and credential/record logging strengthened. |
| 7: remote status race | Fixed with a shared row lock and fresh status/metadata. |
| 8: registration audit/event inside transaction | Fixed; emitted after commit. |
| 9: malformed URL/code logging | Fixed; validate/encode before connecting and classify errors. |
| 10: bad record aborts remap pull | Fixed; isolate and count per record. |
| 11: malformed key spoils prefetch | Fixed; unavailable prefetch falls back to current individual lookups. Repeated keys were fixed too. |
| 12: local status preconditions | Fixed; also protect status changes through generic settings saves. |
| 13: empty REST charging | Fixed; cancel when no rows are sent. |
| 14: exception details in socket replies | Fixed; translated atom messages or a generic response. |
| 15: malformed channel table | Fixed; table/ref guards. |
| 16: socket outlives session | Fixed on both socket implementations. |
| 17: inspected values / non-finite numerics | Fixed; unsupported markers and explicit numeric forms, with DB round trips. |
| 18: false changed fields | Fixed; use cast changes. |
| 19: transport structs in flashes | Fixed on the table-fetch/pull HTTP boundaries; older unrouted Sender/Receiver formatting remains. |
| 20: History badge/strategy translation | Deferred; see the review's remaining-work section. |
| 21: response deadline | Fixed using Finch's complete-response timeout. |
| 22: unbounded/untranslated transfer failures | Fixed for pulls; classified stored reasons, with legacy text preserved. |
| 23: socket table/schema shapes | Fixed, with schema validation shared by HTTP. |
| 24: unsafe Regenerate Token UI | Removed; older-tab events cannot rotate. Coordinated low-level API use remains documented. |
| 25: refresh fan-out / deterministic retries | Deferred for a focused policy change. |

Additional fixes: Ecto credential redaction/query logging, repeated-key conflict handling, run references for late/queued sync messages, and delete notification after local commit. PR #30 now carries its security floor in published dependency requirements.
