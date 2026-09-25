# AGENTS.md

Guidance for AI agents working on `phoenix_kit_sync`.

## Overview

PhoenixKit Sync moves data table by table between PhoenixKit instances
(dev↔prod, dev↔dev, or unrelated sites). It has two modes: **ephemeral
code-based transfers** (a short-lived session code held in `SessionStore`, an
ETS table behind a GenServer that monitors the owning LiveView process, so the
session dies with the page) and **permanent token-based connections** (a
stored `auth_token_hash` with per-table access control, IP whitelist, time
windows, download and record limits). It ships admin LiveViews, a REST API and
a WebSocket protocol for cross-site communication, and Oban-backed batch
import. Implements `PhoenixKit.Module`; it is a library and borrows the host's
Repo, Endpoint and Settings.

- **Depends on:** `phoenix_kit` `>= 2.38.0 and < 3.0.0` (Hex; the floor is functional, see Landmines). No sibling `phoenix_kit_*` deps. Other runtime deps: `websockex` (WebSocket client towards a remote sender), `websock_adapter` (server-side upgrade), `oban` (import jobs), `jason`.
- **Consumed by:** nothing yet.
- **Admin surface:** tab `:admin_sync` "Sync" at `sync` (group `:admin_modules`, priority 640, `match: :prefix`) with subtabs Overview `sync` (`Web.Index`), Connections `sync/connections` (`Web.ConnectionsLive`), History `sync/history` (`Web.History`). Public: REST API under `<url_prefix>/sync/api/*` and a WebSocket forward at `<url_prefix>/sync/websocket`, both from `route_module/0`.
- **Module key** `"sync"`; settings prefix `sync_`; permission key `"sync"`.

## What this module does NOT do

Deliberate non-features. If a review proposes one, surface it to the
maintainer instead of implementing it.

- **No auto-sync scheduler.** `auto_sync_enabled`, `auto_sync_tables` and `auto_sync_interval_minutes` exist on the schema; the worker that would consume them is intentionally absent. Connections sync only when an admin clicks through the receiver flow or a remote peer pulls.
- **No per-record encryption at rest.** Auth tokens are hashed (`auth_token_hash`); record payloads are stored and transferred in plaintext over TLS. Field-level encryption is out of scope.
- **No webhook retry layer.** `ConnectionNotifier` fires one best-effort outbound HTTP request; it does not queue, retry or back off. Any future retry goes through Oban, not queue logic inside this module.
- **No pre-sync snapshots or data versioning.** `Transfer` rows record what moved and when; target tables are not snapshotted.
- **No diff/merge UI.** Conflict resolution is per table (`:skip | :overwrite | :merge | :append`, field-level merge only); there is no row-level merge or three-way diff view.
- **No DNS-rebinding mitigation on `connection.site_url`.** `validate_base_url/1` rejects RFC1918, loopback, link-local, `.local` and non-`http(s)` URLs at changeset time; deployments that legitimately point at internal hosts opt in with `config :phoenix_kit_sync, allow_internal_urls: true`. A public hostname that resolves to an internal IP only at request time is not guarded: resolution-at-request-time is racy and the acute threat is the literal-IP form (cloud metadata is always `169.254.169.254`).
- **No bulk operations across connections.** Approve, suspend and revoke act on one connection at a time.

## Commands

```bash
mix deps.get
createdb phoenix_kit_sync_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

`mix precommit` here also runs `deps.unlock --check-unused` and `mix hex.audit`,
so an unused lock entry or a retired dep fails it.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.
- `mix test.reset` — drops the test database and recreates it.
- `mix test.setup` — `ecto.create` on the test repo, the alias equivalent of `createdb`.

## Conventions

- Module key `"sync"`; tab ids `:admin_sync_*`; URL segments use hyphens (`sync/connections`, `sync/api/register-connection`). The module test rejects underscores in tab paths.
- Paths: `PhoenixKitSync.Paths` (`index/0`, `connections/0`, `history/0`) wraps `PhoenixKit.Utils.Routes.path/1`; LiveViews that need a locale call `Routes.path(path, locale: locale)`. Never hardcode a URL prefix.
- Routing uses both patterns. Admin LiveViews come from `live_view:` on the tabs; public routes come from `route_module/0` = `PhoenixKitSync.Routes.generate/1`, a `scope` piped through `:phoenix_kit_api` plus a `forward` to `Web.SocketPlug`. `admin_routes/0` and `admin_locale_routes/0` are unused here and may hold only `live` declarations (`live_session` rejects controllers, `forward`, nested `scope` and `pipe_through`), so every non-LiveView route belongs in `generate/1`. Never hand-register these LiveViews in a host router: they would mount outside the `:phoenix_kit_admin` live_session and crash on navigation. Core's `guides/custom-admin-pages.md` is the reference.
- Every admin LiveView is `use PhoenixKitWeb, :live_view` followed by `use Gettext, backend: PhoenixKitWeb.Gettext`; templates never wrap in `LayoutWrapper`. `ApiController` is `use PhoenixKitWeb, :controller`.
- Gettext: core's `PhoenixKitWeb.Gettext`; there is no `priv/gettext` here. Core's `mix gettext.extract` walks only core's `lib/` and core carries no sync manifest, so these strings render as their English msgid until a `sync_gettext_manifest.ex` (the comments/legal/projects pattern in core) lists them. Keep every `gettext/1` argument a literal string so the extractor and grep can see it; do not refactor `Errors.message/1` into a lookup map.
- JS hooks: none. `css_sources/0` returns `[:phoenix_kit_sync]` so the host's `:phoenix_kit_css_sources` compiler scans this module's templates for Tailwind classes.
- `enabled?/0` rescues and catches `:exit`, returning `false` (a sandbox-owner exit in a non-DataCase test surfaces as `:exit`, not an exception).
- Activity logging: every state-changing operation in `Connections` calls `log_sync_activity/4`, which persists `sync.connection.<verb>` (created, updated, deleted, approved, suspended, revoked, reactivated; `resource_type: "sync_connection"`, `mode: "manual"`, actor via the `actor_uuid:` opt). `Transfers` logs `sync.transfer.<verb>` (created, approved, denied, cancelled, completed, failed; `resource_type: "sync_transfer"`). `ImportWorker` logs `sync.import.batch_completed` with `mode: "auto"`. All three call core's `PhoenixKit.Activity.log/3`, which never raises, so a missing activities table never fails the primary operation. **PII rule:** metadata carries `connection_name`, `direction`, `status`, `reason` (transfers: `table_name`, `direction`, `status`, record counts) and never `site_url` or any token field; the audit feed is visible to other admins.
- Soft-delete: none. Deletes are hard.
- Errors: context functions return `{:error, atom}`; `PhoenixKitSync.Errors.message/1` translates at the UI/API boundary and has a clause for every atom the module emits; unknown atoms fall through to `inspect/1`. Never return free-text error strings from context code.
- **SQL identifier safety:** validate every table/column name with `SchemaInspector.valid_identifier?/1` and wrap it in double quotes (`~s["#{name}"]`) before interpolating into raw SQL. Values are always parameterised `$N` binds via `repo.query(sql, [binds])`, never concatenated. Reference: `DataImporter.find_existing/4` and `insert_record/3`.
- `SchemaInspector` never lists or syncs `schema_migrations`, `oban_*`, `pg_*` or `phoenix_kit_user_tokens`.
- Sender-side authorization: `list-tables`, `pull-data`, `table-schema` and `table-records` filter through `Connection.table_allowed?/2` (the `excluded_tables` blocklist and, when set, the `allowed_tables` allowlist), so a leaked token never grants blanket DB access.
- PubSub: `Connections` broadcasts on `PhoenixKit.Config.pubsub_server()` under `Connections.pubsub_topic/0` (`"sync:connections"`): `{:connection_created, uuid}`, `{:connection_updated, uuid}`, `{:connection_status_changed, uuid, status}`, `{:connection_deleted, uuid}`. Subscribe via the function, not the literal; never add duplicate broadcasts in controllers or LiveViews.
- Task supervision: async work in LiveViews is either `Task.start_link/1` (render-only fetches that should die with the LiveView) or `PhoenixKitSync.AsyncTasks.notify_remote_async/1` (`Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, ..., restart: :temporary)`, for notifications that must complete after a DB commit even if the admin closes the tab). Bare `Task.start/1` is forbidden.
- Oban: batch imports go through `Workers.ImportWorker` (queue `:sync`, `max_attempts: 3`); the host must add `sync` to its Oban queues. Never spawn bare Tasks for import work.
- `Connection.ip_allowed?/2` returns `true` for both `[]` and `nil` whitelists, matching the 1-arity form, so callers can pass a real client IP without special-casing an empty whitelist.
- Self-connection protection: `Connections.create_connection/1` rejects `"sender"` connections to the site's own URL (scheme, port and case normalised). Receivers (API-created) are always allowed.
- Site identity: `ConnectionNotifier.get_our_site_url/0` reads core's `site_url` setting, then `config :phoenix_kit, :public_url`, then the dynamic base URL. `remote_url_prefix/0` mirrors the local URL prefix unless `config :phoenix_kit_sync, remote_url_prefix:` overrides it; the value is normalised (leading slash ensured, trailing slash stripped, `""`/`"/"` collapse to no prefix).
- Decimal values: `DataExporter` serialises `Decimal` to strings for JSON; `ConnectionNotifier.Prepare` parses decimal-like strings (`"0.00"`) back to `Decimal` before INSERT, otherwise numeric columns fail with Postgrex type errors.
- Suggested tables: when tables are selected for sync, tables referencing them via FK are highlighted as suggested, never auto-selected. The admin decides.
- Ecto schemas use `:integer` (not `:bigint`) and `:string` (not `:text`); the migration-only types do not compile in a schema.

### Landmines

- `Connections.create_connection/1` needs string-keyed attrs: it injects `"auth_token"` as a string key, and atom-keyed input then fails with `Ecto.CastError`.
- The `*_by_uuid` actor columns on both tables are real FKs to `phoenix_kit_users`: a fresh `UUIDv7.generate()` raises `Ecto.ConstraintError`. Use `PhoenixKitSync.TestActor.uuid/0`; plain `UUIDv7.generate()` is fine only for non-FK uuid fields (a string there raises `Ecto.ChangeError`).
- `PhoenixKitSync.Migration.up/1` is built on `Ecto.Migration` macros and raises outside a migrator process; call it from a host migration file or via `Ecto.Migrator.up/4`.
- `SessionStore` owns one global ETS table: tests start it in `setup_all` and accept `{:error, {:already_started, _}}`; a per-test `start_link` fails.
- `enabled?/0` and `get_config/0` hit the DB. Without `config :phoenix_kit, repo: ...` every `PhoenixKit.RepoHelper` call dies with "No repository configured"; in unit tests assert on `function_exported?/3` or tag `:integration`.
- `connections_live.ex` renders the tab strip with `variant={:border}`, which core's `nav_tabs` only accepts from **2.13.6** on. Below that the attribute fails `attr :values` validation and the module does not compile — a failure that reads as an attribute typo, not a version problem. The requirement was raised to `>= 2.13.6` for exactly this reason (it is `>= 2.38.0 and < 3.0.0` now, for `PhoenixKitWeb.Actor` and `Activity.log/3`), and `core_pin_conformance_test.exs` asserts the floor; `mix.lock` is not published to Hex, so the requirement is the only thing that protects a consumer. If a local checkout still fails this way, its lock predates the floor: `mix deps.update phoenix_kit`.
- `sync_channel_test.exs` replies are served by a live Postgres introspection query, so `assert_push`'s default 100 ms deadline loses the race on a loaded machine and reports an empty mailbox as a protocol failure. Those assertions carry an explicit `@reply_timeout`; keep it on any new DB-backed reply.

## Architecture

```
lib/phoenix_kit_sync.ex                    # PhoenixKit.Module impl, settings accessors, session + inspection facade
lib/phoenix_kit_sync/
├── connection.ex / connections.ex         # Connection schema + context (CRUD, guards, activity log, PubSub)
├── transfer.ex / transfers.ex             # Transfer schema + context (lifecycle, approval workflow)
├── errors.ex                              # error atom -> gettext string, single translation point
├── schema_inspector.ex                    # DB introspection (tables, columns, FKs, counts); valid_identifier?/1
├── data_exporter.ex                       # paginated + streamed export
├── data_importer.ex                       # import with conflict strategies; parameterised SQL, batched find_existing
├── connection_notifier.ex (+ /prepare.ex) # HTTP client to the remote site; value/record transformation, FK remap
├── session_store.ex                       # ETS + GenServer for code-based sessions (owner monitoring)
├── async_tasks.ex                         # notify_remote_async/1
├── column_info.ex / table_schema.ex       # structs
├── client.ex / channel_client.ex / websocket_client.ex   # client side of the sync protocol (heartbeat)
├── paths.ex / routes.ex                   # path helpers; route_module/0 target
├── migration.ex                           # standalone CREATE TABLE IF NOT EXISTS fallback
├── web/
│   ├── api_controller.ex (+ /validators.ex)  # REST API; param-shape validators
│   ├── socket_plug.ex / sync_websock.ex   # WebSocket upgrade (code or token) + WebSock handler
│   ├── sync_socket.ex / sync_channel.ex   # Phoenix Socket/Channel variant of the server side
│   ├── index.ex                           # Overview dashboard
│   ├── connections_live.ex (+ /status.ex) # connection management; async status/verify helpers
│   ├── history.ex                         # transfer log
│   ├── sender.ex / receiver.ex (+ receiver/helpers.ex)  # code-based flow (see TODOs: unrouted)
└── workers/import_worker.ex               # Oban worker, queue :sync
```

**Data model** (UUIDv7 PKs, `use PhoenixKit.SchemaPrefix`):

| Schema | Table | Holds |
|--------|-------|-------|
| `Connection` | `phoenix_kit_sync_connections` | direction (`"sender"`/`"receiver"`), `site_url`, `auth_token_hash`, status, approval mode, allowed/excluded/auto-approve tables, limits, IP whitelist, allowed hours, stats, actor FKs |
| `Transfer` | `phoenix_kit_sync_transfers` | direction, session code, table, record counts, conflict strategy, status, approval fields, requester context, actor FKs |

Full column lists: `docs/table_structure.md`.

**Settings keys:** `sync_enabled` (boolean), `sync_incoming_mode` (`"auto_accept" | "require_approval" | "require_password" | "deny_all"`, default `"require_approval"`), `sync_incoming_password`. Reads core's `site_url` setting.

**App env:** `config :phoenix_kit_sync, allow_internal_urls: boolean` (default `false`), `remote_url_prefix: string` (default: mirror the local prefix). Falls back to `config :phoenix_kit, :public_url` for the site URL.

**Permissions:** `"sync"` (from `permission_metadata/0`); no sub-permissions.

**PubSub:** topic `"sync:connections"` (`Connections.pubsub_topic/0`), events listed under Conventions.

**Supervision:** `children/0` starts `SessionStore`.

**API endpoints** (all under the configured URL prefix, default `/phoenix_kit`):

| Method | Path | Handler | Auth |
|--------|------|---------|------|
| POST | `/sync/api/register-connection` | Register incoming connection | Module enabled + incoming mode not `deny_all` + password when required |
| POST | `/sync/api/delete-connection` | Delete a connection | Module enabled + `sender_url` and `auth_token_hash` match a connection |
| POST | `/sync/api/verify-connection` | Verify connection exists | Module enabled + `sender_url` and `auth_token_hash` match |
| POST | `/sync/api/update-status` | Update connection status | Module enabled + `sender_url` and `auth_token_hash` match |
| POST | `/sync/api/get-connection-status` | Query connection status | Module enabled + `receiver_url` and `auth_token_hash` match a sender connection |
| POST | `/sync/api/list-tables` | List available tables | Token hash + active connection; filtered by `table_allowed?/2` |
| POST | `/sync/api/pull-data` | Pull table data | Token hash + active connection + table allowed |
| POST | `/sync/api/table-schema` | Get table schema | Token hash + active connection + table allowed |
| POST | `/sync/api/table-records` | Get table records | Token hash + active connection + table allowed |
| GET | `/sync/api/status` | Check module status | None |
| WS | `/sync/websocket` | WebSocket sync protocol | `?code=` (ephemeral session) or `?token=` (permanent connection) |

## Database & migrations

None. Tables `phoenix_kit_sync_connections` and `phoenix_kit_sync_transfers`
ship in core's chain (V135 baseline); `migration_module/0` is unset. A schema
change is a core migration first, then schema edits here.

`PhoenixKitSync.Migration` is a standalone fallback, not a chain: `up/1` and
`down/1` take `:prefix`, use `CREATE TABLE IF NOT EXISTS` and `IF NOT EXISTS`
indexes, add FKs to `phoenix_kit_users` only when that table exists, and
`down/1` drops both tables. It mirrors core's shape for installs where core's
migrations have not run; when the table shape changes in core, change it here
too.

Always: UUIDv7 PKs (`@primary_key {:uuid, UUIDv7, autogenerate: true}`, DB
default `uuid_generate_v7()`), `use PhoenixKit.SchemaPrefix` on both
table-backed schemas (`test/schema_prefix_conformance_test.exs` enforces it).

## Testing

Test DB `phoenix_kit_sync_test` (suffix `MIX_TEST_PARTITION` if set);
`PGUSER`, `PGPASSWORD`, `PGHOST` are honoured (defaults `postgres`/`postgres`/
`localhost`). `test_helper.exs`
probes `psql -lqt` for the DB, and without it excludes `:integration`. Pure
unit tests (schemas, changesets, SessionStore, Errors, Paths, worker job
building, pure LiveView helpers) run regardless; DB-backed tests are every
file under `test/integration/` plus the `LiveCase`/`ChannelCase`/`DataCase`
files under `test/phoenix_kit_sync/web/`, so `mix test test/phoenix_kit_sync/`
is not "unit only".

With the DB, the helper builds the schema with
`PhoenixKit.Migration.ensure_current(TestRepo, log: false)` (no module DDL),
then starts `PhoenixKit.PubSub.Manager`, `PhoenixKit.ModuleRegistry`,
`PhoenixKit.Users.RateLimiter.Backend` (user registration needs its ETS
table), `PhoenixKit.TaskSupervisor`, `SessionStore`, `Phoenix.PubSub`
(`PhoenixKitSync.Test.PubSub`), `Finch` (`PhoenixKit.Finch`) and
`PhoenixKitSync.Test.Endpoint` on a random port (stored in app env
`:test_endpoint_port` so tests can build reachable localhost URLs). It pins the
URL prefix to `""` in `:persistent_term` so mounts do not query settings.

`config/test.exs` wires `config :phoenix_kit, repo: PhoenixKitSync.Test.Repo`
and sets `allow_internal_urls: true` so localhost URLs pass the SSRF guard;
`connection_ssrf_test.exs` flips it back to `false` to verify rejections, and
any new test that expects a rejection must do the same.

Support modules (`test/support/`):

- `DataCase` (sandbox + `:integration`, imports `ChangesetHelpers.errors_on/1`), `ConnCase` (`Phoenix.ConnTest` against `Test.Endpoint`), `LiveCase` (`Phoenix.LiveViewTest`; `fake_scope/1` builds a `PhoenixKit.Users.Auth.Scope` with the `"sync"` permission, `put_test_scope/2` puts it in the session), `ChannelCase` (`Phoenix.ChannelTest` for `SyncSocket`/`SyncChannel`).
- `Test.Endpoint` / `Test.Router` / `Test.Layouts` / `Test.Hooks`: the router mounts the LiveViews at `/en/admin/sync/*` (plus `/sync/send`, `/sync/receive`) inside a `live_session` whose `on_mount` hook assigns `:phoenix_kit_current_scope` from the session, and mirrors the API at both `/sync/api/*` and `/phoenix_kit/sync/api/*` plus the WebSocket forward at both prefixes. Flashes render with ids `flash-info`/`flash-error`/`flash-warning`.
- `TestActor.uuid/0`: a real registered user for actor FKs. `ActivityLogAssertions.assert_activity_logged/2`: exactly one activity row for an action, with `:resource_uuid`, `:actor_uuid`, `:metadata_has` filters.
- `core_pin_conformance_test.exs` asserts the `:phoenix_kit` floor (2.13.6, see Landmines) and that the upper bound still admits every later 2.x — a requirement pinned to one minor breaks `mix deps.get` for hosts.

```bash
mix test --exclude integration       # unit only
mix test --only integration          # DB-backed only
mix test test/integration/full_sync_flow_test.exs   # end-to-end export -> import
```

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s and the README;
table shapes are in `docs/table_structure.md`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

`dev_docs/pull_requests/README.md` and `TEMPLATE.md` describe the folder
layout and the per-PR `README.md`.

## TODOs

- `Web.Sender` and `Web.Receiver` (the code-based flow) have no production route: neither `admin_tabs/0` nor `Routes.generate/1` mounts them, only `test/support/test_router.ex` does (`/sync/send`, `/sync/receive`). Add tabs or `admin_routes/0` entries before pointing users at that flow.
- Sync strings have no manifest in core, so they render untranslated. Add a `sync_gettext_manifest.ex` in core (the comments/legal/projects pattern) when a translated sync UI is needed.
