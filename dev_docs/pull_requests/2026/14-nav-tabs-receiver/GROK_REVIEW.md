# Grok Review — PR #14 "Use core's nav_tabs for the receiver tab strip, and fix the daisyUI tabs class"

**Merge commit:** fe632b6
**Author:** mdon (fix/daisyui-tabs-box)
**Files:** `lib/phoenix_kit_sync/web/receiver.ex`

## Summary of the change

The receiver's Bulk Transfer / Table Details strip was a hand-rolled copy
of core's `<.nav_tabs>` (container classes, `phx-value-tab` payload, the
dead `tabs-boxed` class). It now calls the component. `active_tab` is an
atom assign (`:global` / `:table_details`); the component compares
string ids, so the call site uses `to_string(@active_tab)`. The handler
already matches `%{"tab" => "global"}` and re-assigns the atom.

## Findings

### 1. BUG - HIGH — four tests still passed a random UUID as an actor

`phoenix_kit_sync_connections` / `phoenix_kit_sync_transfers` carry real
FKs onto `phoenix_kit_users` (`fk_sync_*_approved_by_uuid` etc.). The
suite already has `PhoenixKitSync.TestActor` for this — `create_connection`
in the same transfers file uses it — but the approval-workflow tests
still called `UUIDv7.generate()`, and two LiveView tests used
`fake_scope()` whose user is a map with a random uuid, never inserted.
Against core 2.13.5 those four tests raise `Ecto.ConstraintError`.
**Fixed:** `TestActor.uuid()` everywhere an actor is attributed.

### 2. BUG - MEDIUM — `version/0` test still asserts `"0.1.0"`

`PhoenixKitSync.version/0` is `"0.2.1"` (and this release moves it to
`0.2.2`), but `test/phoenix_kit_sync/module_test.exs` still asserts
`"0.1.0"`. The suite would fail the moment anyone runs it. **Fixed** as
part of the version bump — the same class of drift user_connections
called out in 0.2.2.
