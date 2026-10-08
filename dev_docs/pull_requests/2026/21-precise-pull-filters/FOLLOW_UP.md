# Second-review follow-up for PR #21

**Date:** 2026-10-08
**Agent:** GPT / Codex

Remap-aware pulls now validate and send precise filters, require the sender's confirmation before writing, map sender filter errors, and preserve the incoming remap on refusal. Three integration regressions failed on `6449822` and pass with the fix.

The existing bulk caller remains unfiltered. Claude's ID parsing and preview error-code fixes are retained. Final full suite: **848 tests, 0 failures**; `mix precommit` passed.
