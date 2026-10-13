# Follow-up for PR #9: `format_error/1` and the Mint error structs

Review: `CLAUDE_REVIEW.md` (three critical findings, two process concerns).
Each was re-read against the current code by reading it.

## Fixed (pre-existing)

- ~~**#1** The `Mint.*` heads never match what `Finch.request/3` returns~~.
  `lib/phoenix_kit_sync/connection_notifier.ex:1743-1759` matches
  `%Finch.TransportError{}`, `%Finch.HTTPError{}` and `%Finch.Error{}`, each
  head gated with `Code.ensure_loaded?/1` (the review's Option A). No
  `Mint.` reference remains in the file. The `{:exception, msg}` clause
  (`:1761`) and the `inspect/1` catch-all (`:1765`) are kept, as the review
  asked.
- ~~**#2** The comment said Finch has no error structs of its own~~. The
  comment at `connection_notifier.ex:1735-1742` names the three `Finch.*`
  structs, says `Mint.*` errors are wrapped before they are returned, and
  gives the compile-order reason for the gate.

## Fixed (Batch 1 — 2026-10-13)

- ~~**#3** No test reached `format_error/1`~~.
  `test/integration/notifier_transport_errors_test.exs:46-65` drives a real
  request into a closed port and into a listener that answers non-HTTP, and
  asserts `"Connection failed: :econnrefused"` and an `"HTTP error: "` text
  that contains neither `%` nor `Finch`. The test at `:67` asserts the same
  failures on a pull are classified `:offline` and the transfer row is closed
  as failed.

## Skipped (with rationale)

- **Process #1** Verification claims did not cover the change. A note on how
  the PR was verified; the review asks for no code change beyond the test
  above.
- **Process #2** Dialyzer state after the merge. The review asked for a check
  of whether the unreachable `Mint.*` pattern was flagged; those heads no
  longer exist, and `.dialyzer_ignore.exs` carries no entry for
  `connection_notifier.ex`.

## Files touched

| File | Change |
|------|--------|
| `test/integration/notifier_transport_errors_test.exs` | new: transport and protocol failures through a real request |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

None.
