# PR #33: Enforce the per-minute rate limit, previews on demand, local approval for sender connections

**Status:** Merged and reviewed before publication on 2026-10-14.

`rate_limit_requests_per_minute` is now counted inside `Connections.authorize_request/3` (core's Hammer backend, per node, default 600, `0` is no limit); REST answers 429 + `Retry-After`, the upgrade 429, an open socket `response:error` with `error_code`/`retry_after`, and the receiving side (`ConnectionNotifier.make_limited_request/5`, `WebSocketClient`) waits the 429 out within a clamped budget (`PhoenixKitSync.RateLimit`). The sync page shows "Rate limited by the sender" and asks for a preview only on a click. The connection form never takes a `status`. The unused `requires_approval?/2` and `expire_connections/0` are removed.

Reviews: [Claude](CLAUDE_REVIEW.md).
