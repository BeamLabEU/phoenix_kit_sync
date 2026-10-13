# Follow-up for PR #17: actor and activity logging through core

Review: `GROK_REVIEW.md`. Each finding was re-read against current `main` by
reading the code; the suite was not run for this triage.

## Fixed (pre-existing)

- ~~**#1** Connection drill-down pages never left the list trail~~.
  `assign_trail/2` (`lib/phoenix_kit_sync/web/connections_live.ex:2900-2940`)
  is called on every transition (`:45`, `:90`, `:115`, `:135`, `:150`, `:157`,
  `:167`, `:181`). Pinned in
  `test/phoenix_kit_sync/web/connections_live_test.exs:333-362`.
- ~~**#2** `sync.connection.created` dropped the creator~~.
  `lib/phoenix_kit_sync/connections.ex:187` passes
  `actor_uuid: connection.created_by_uuid`. Pinned in
  `test/integration/connections_test.exs:585-595`.
- ~~**#3** The empty-change guard used a random actor uuid~~.
  `test/phoenix_kit_sync/connections_activity_test.exs:28` uses
  `PhoenixKitSync.TestActor.uuid()`.

## No action (per the review's "Left as they are")

- In-page headings stay as they are; the review scopes them out.
- A failed activity INSERT inside an open transaction belongs in core.
- `Web.Sender` and `Web.Receiver` have no production route. Still true, and
  listed under TODOs in `AGENTS.md`.

## Open

None.
