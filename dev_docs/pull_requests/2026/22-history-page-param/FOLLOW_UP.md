# Follow-up for PR #22: bad page, offset and limit values

Reviews: `CLAUDE_REVIEW.md`, `GPT_REVIEW.md`. Both raise the same single
finding; it was re-read against the current code by reading it.

## Fixed (pre-existing)

None.

## Fixed (Batch 1 — 2026-10-13)

- ~~**#1 (both reviews)** A clamped history page kept its out-of-range
  URL~~. `lib/phoenix_kit_sync/web/history.ex:99` compares the requested
  page with the one `load_transfers/1` settled on (`:129`) and, when they
  differ on a connected socket, `push_patch`es to `history_path/2`
  (`:105-116`) with `replace: true`, keeping the direction and status filters.
  Pinned by `test/phoenix_kit_sync/web/history_live_test.exs:256`
  (`?page=999` is patched to `?page=2`).

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_sync/web/history.ex` | address follows the clamped page |
| `test/phoenix_kit_sync/web/history_live_test.exs` | clamp-to-address test |

## Verification

`mix test` 1899 tests, 0 failures. `mix precommit` clean (compile with warnings as errors, format, credo --strict, dialyzer).

## Open

None.
