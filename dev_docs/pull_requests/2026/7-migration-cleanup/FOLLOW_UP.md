# Follow-up for PR #7: migration cleanup

Review: `CLAUDE_REVIEW.md`. Each finding was re-read against current `main`
by reading the code; the suite was not run for this triage.

## Fixed (pre-existing)

- ~~**#3** Deep-link `?action=show|edit|sync&id=` queried during the dead
  render~~. `lib/phoenix_kit_sync/web/connections_live.ex:100-107` gates the
  dispatch on `connected?(socket)`; `dispatch_resource_action/3` follows at
  `:119-126`. The catch-all clause and `mount/3` go through
  `maybe_load_connections/1` (`:55`, `:66`, `:116`). Pinned by the dead-render
  and live-render tests in
  `test/phoenix_kit_sync/web/connections_live_test.exs:166-240`.

## No action (per the review)

- **#1** Merged before the upstream release was published. A process note; the
  review asks for no change. `mix.exs:100` now requires
  `>= 2.38.0 and < 3.0.0`, far past the release that added `ensure_current/2`.
- **#2** Two quality fixes bundled into a migration PR. A process note.
- **#4** `schema_migrations` gains one row per `mix test`. The review records
  it as accepted; `test/test_helper.exs:65` still calls
  `PhoenixKit.Migration.ensure_current(TestRepo, log: false)`.

## Open

None.
