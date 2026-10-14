# Claude review of PR #33: Enforce the per-minute rate limit, previews on demand, local approval for sender connections

**Reviewer**: Claude (read-only pass over the PR diff and the code it touches; the DB-backed tests were not run, there is no database in the review environment).

The limit is counted in one place (`authorize_request/3`), after every check a stranger can fail and before the password, so no entry point can skip it; the socket passes `rate_limit: false` only for non-`request:*` frames; REST, upgrade and socket each refuse with the shape the README documents. The receiving side clamps the peer's `Retry-After` (`RateLimit.next_wait/2`, missing or hostile values fall back to 5 s) and bounds the total wait per request. `Web.Receiver` has a catch-all for the new `{:sync_client, {:rate_limited, ...}}` message, and `Client.wait_for_response/2` handles it. Checked `hit/3`'s `rescue ArgumentError` (missing ETS table lets the request through, with a warning) and the header capture in `request_capped/3`.

## 1. BUG - MEDIUM: a pull that gives up on a 429 shows the raw atom name in History

`fetch_pull_page/2` classifies `{:error, :rate_limited}` through `transport_reason/1` and the transfer row stores `"rate_limited"`. `Errors.transfer_error/1` translates a stored name only when it is in `@stored_errors`, and `rate_limited` was not: History showed the literal `rate_limited` instead of "Too many requests to the sending site; it asked to wait and the wait ran out" (which the PR did add to the catalogue, so it was unreachable from there).

**Resolution:** Fixed. `rate_limited` joins `@stored_errors`; `errors_test.exs` asserts `transfer_error("rate_limited")` is the translated message.

## 2. NITPICK: `docs/table_structure.md` still listed the default as 60

The schema default and the standalone migration moved to 600.

**Resolution:** Fixed in the doc.

## 3. NITPICK: a comment in `errors.ex` sat above the wrong clause

The new `message({:rate_limited, seconds})` clause was inserted between the comment about the key type and the `{:truncated_key_type, type}` clause it describes.

**Resolution:** Fixed; the clause moved above the comment.

## 4. NITPICK: `Client.wait_for_response/2` restarts the full timeout on a rate-limited notice

The recursion passes `timeout + seconds * 1000`, not the time left plus the wait, so each notice grants a fresh timeout. It is bounded by the wait budget (300 s default) and the socket sender is the only party that triggers it.

**Resolution:** Not changed.

## 5. NITPICK: a stale rate-limit notice has no run reference

`{:sync_rate_limited, seconds}` carries no sync-run reference, unlike the other task replies, so a task of a closed run can show the notice on a reopened page until its timer (the wait, at most 60 s) clears it. Cosmetic: it changes no state.

**Resolution:** Not changed.

## 6. NITPICK: stale assertion in `batch_2_revalidation_test.exs`

It still refutes the `expire_connections` `@doc` example, a function this PR removed. It passes trivially.

**Resolution:** Not changed; harmless.

## Existing connections keep their old limit

Rows created before this PR hold the old default of 60 requests per minute, and the limit is now enforced on them. A sync of a full install makes 200+ requests, so it waits the minute out (inside the 300 s budget) rather than failing. The README and the PR title point at core V218; nothing to change here.
