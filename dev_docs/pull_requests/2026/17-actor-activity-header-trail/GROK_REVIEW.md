# Grok Review — PR #17 "Actor and activity logging through core"

**Merge commit:** `58603f9`
**Author:** mdon
**Files:** `AGENTS.md`, `connections.ex`, `transfers.ex`, `import_worker.ex`, `connections_live.ex`, `history.ex`, `index.ex`, `receiver.ex`, `sender.ex`, `mix.exs`, `mix.lock`, `core_pin_conformance_test.exs`, `connections_activity_test.exs`

## Summary of the change

Admin mutations read the acting user through `PhoenixKitWeb.Actor` instead of
`socket.assigns.phoenix_kit_current_scope.user`. Activity rows go through
`PhoenixKit.Activity.log/3` (module `"sync"`) and drop the local
`Code.ensure_loaded?` + `rescue`. The import worker still passes
`mode: "auto"` and no actor. The core requirement moves to
`>= 2.38.0 and < 3.0.0`, the release that first shipped `Actor` and
`Activity.log/3`. Sub-pages set `page_section` to Sync; Overview's title
becomes `Sync`.

Checked against core 2.40.1 (the locked checkout): `log/3` defaults `mode` to
`"manual"` and never raises (rescue and catch), and `Actor.uuid/1` prefers
the scope, then `phoenix_kit_current_user`, and returns `nil` when nobody is
signed in. Approve, deny, suspend and revoke changesets already turn a
non-binary actor into `nil`.

## Findings

### 1. BUG - MEDIUM — connection drill-down pages never left the list trail

The header commit set `page_section` and a single `page_title` in `mount/3`.
New, show, edit and sync are addressable pages of the same LiveView
(`?action=new`, `?action=show&id=`, `?action=edit&id=`, `?action=sync&id=`),
and none of them changed the title or set `page_crumbs`. The bar stayed
`Sync / Connections` on every one of them, which is the lost level the header
guide forbids: the edit page must be the record page's trail plus the record.

Overview, History, Send and Receive match the guide as they stand. Overview
is the landing page (title `Sync`, no section). The other three are one page
each; History's approval UI is a modal, not another level. Sender and
Receiver steps are not URL levels.

**Fixed:** `assign_trail/2` on every transition.

| View | Title | Crumbs |
|---|---|---|
| list | Connections | none |
| new | New connection | Connections |
| show | the connection's name | Connections |
| edit | Edit | Connections, the name (patch to show) |
| sync | Sync data | Connections, the name (patch to show) |

A missing id, and cancel back to the list, clear the crumbs. A deep-linked
show, edit or sync keeps the list trail on the dead render: the name needs a
query, and that query stays gated on `connected?/1`. The connected render
fills the trail in. Covered by `connections_live_test.exs`.

### 2. BUG - MEDIUM — `sync.connection.created` dropped the creator

`ConnectionsLive` writes `created_by_uuid` from `Actor.uuid/1`, and that
column is a real user FK. `do_insert_connection/1` then called
`log_sync_activity("created", connection, [])`, so the audit row's actor was
always `nil`. The same PR's other verbs pass the actor through.

**Fixed:** the created row uses `connection.created_by_uuid`. A create with
no creator (the API path) still logs a nil actor. `connections_test.exs`
pins both, and pins `module` `"sync"` and `mode` `"manual"` so the `log/3`
default cannot drift.

### 3. NITPICK — the empty-change regression guard used a random actor UUID

`connections_activity_test.exs` passed `UUIDv7.generate()` as `actor_uuid`.
`phoenix_kit_activities.actor_uuid` has no database FK today, so the insert
landed and the count assertion passed. The changeset already declares
`foreign_key_constraint(:actor_uuid)`. The day that constraint exists,
`log/3` swallows the failure and the guard fails closed (the count does not
move) rather than checking a real write. **Fixed:** `TestActor.uuid/0`.

## Left as they are

- **In-page headings.** The centered h1 stays "Connections" on every view,
  and the form titles stay "New Connection" / "Edit Connection". Those
  strings are what the page says when `show_page_descriptions` is off, so
  they were not moved into `page_subtitle`. The bar is the trail; the
  in-page headings are a separate layout pass.
- **A failed activity INSERT inside an open transaction.** `log/3` rescues
  in Elixir and does not open a savepoint. Postgres still aborts the
  surrounding transaction. That was true of the old `rescue` too, and the
  savepoint belongs in core.
- **Sender and Receiver have no production route.** Still the module TODO.
  Their section and title are set for the day a host mounts them.

## Tests

`connections_live_test.exs`, `connections_test.exs` and
`connections_activity_test.exs`: 84 tests, 0 failures. The header assertions
read the assigns the admin layout consumes (`page_section`, `page_title`,
`page_crumbs`). This package has no host admin shell, so the chrome itself
was not opened in a browser.
