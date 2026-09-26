# PR #17: Actor and activity logging through core

**Author**: @mdon
**Reviewer**: Grok
**Status**: Merged
**Commit**: `58603f9`
**Date**: 2026-09-26

## Goal

Read the acting admin through core's `PhoenixKitWeb.Actor`, write activity
rows through `PhoenixKit.Activity.log/3`, and put Sync in the admin header
trail. The core floor moves to `>= 2.38.0 and < 3.0.0`, where those APIs
first shipped.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_sync/connections.ex` | `Activity.log/3`; created row keeps `created_by_uuid` as the actor |
| `lib/phoenix_kit_sync/transfers.ex` | `Activity.log/3` |
| `lib/phoenix_kit_sync/workers/import_worker.ex` | `Activity.log/3` with `mode: "auto"`, no actor |
| `lib/phoenix_kit_sync/web/connections_live.ex` | `Actor.uuid/1`; header trail per view |
| `lib/phoenix_kit_sync/web/history.ex` | `Actor.uuid/1`; section Sync, title History |
| `lib/phoenix_kit_sync/web/index.ex` | Landing title Sync |
| `lib/phoenix_kit_sync/web/sender.ex`, `receiver.ex` | Section Sync |
| `mix.exs`, `test/core_pin_conformance_test.exs` | Floor `>= 2.38.0 and < 3.0.0` |

Review: [GROK_REVIEW.md](GROK_REVIEW.md).

## Related

- Core guide: `phoenix_kit` `dev_docs/guides/2026-09-25-admin-header-trail.md`
- Previous: [#14](/dev_docs/pull_requests/2026/14-nav-tabs-receiver)
