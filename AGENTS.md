# AGENTS.md

Guidance for AI agents working on `phoenix_kit_sync`.

## Overview

PhoenixKit Sync moves data table by table between PhoenixKit instances
(dev↔prod, dev↔dev, or unrelated sites). **The remote peer is not trusted**:
every parameter, table name, record and status it sends is data to check. It
has two modes: **ephemeral code-based transfers** (a short-lived session code held in `SessionStore`, an
ETS table behind a GenServer that monitors the owning LiveView process, so the
session dies with the page) and **permanent token-based connections** (a
stored `auth_token_hash` with per-table access control, IP whitelist, time
windows, download and record limits). It ships admin LiveViews, a REST API and
a WebSocket protocol for cross-site communication, and Oban-backed batch
import. Implements `PhoenixKit.Module`; it is a library and borrows the host's
Repo, Endpoint and Settings.

- **Depends on:** `phoenix_kit` `>= 2.38.0 and < 3.0.0` (Hex; the floor is functional, see Landmines). No sibling `phoenix_kit_*` deps. Other runtime deps: `websockex` (WebSocket client towards a remote sender), `websock_adapter` (server-side upgrade), `oban` (import jobs), `jason`, `gettext`.
- **Consumed by:** nothing yet.
- **Admin surface:** tab `:admin_sync` "Sync" at `sync` (group `:admin_modules`, priority 640, `match: :prefix`) with subtabs Overview `sync` (`Web.Index`), Connections `sync/connections` (`Web.ConnectionsLive`), History `sync/history` (`Web.History`). Public: REST API under `<url_prefix>/sync/api/*` and a WebSocket forward at `<url_prefix>/sync/websocket`, both from `route_module/0`.
- **Module key** `"sync"`; settings prefix `sync_`; permission key `"sync"`.

## What this module does NOT do

Deliberate non-features. If a review proposes one, surface it to the
maintainer instead of implementing it.

- **No auto-sync scheduler.** `auto_sync_enabled`, `auto_sync_tables` and `auto_sync_interval_minutes` exist on the schema; the worker that would consume them is intentionally absent, and no form offers them. Connections sync only when an admin clicks through the receiver flow or a remote peer pulls.
- **No per-transfer approval and no request rate limit.** `approval_mode`, `auto_approve_tables` and `rate_limit_requests_per_minute` are stored and `Connection.requires_approval?/2` answers for them, but no pull is held for approval or throttled. Wiring either in is a protocol change (the receiver has to wait or back off), not a missing call.
- **No scheduled expiry.** `Connections.expire_connections/0` flips the stored status and is called by nothing here; a connection past `expires_at` or its limits is refused per request regardless.
- **No per-record encryption at rest.** Auth tokens are hashed (`auth_token_hash`); record payloads are stored and transferred in plaintext over TLS. Field-level encryption is out of scope.
- **No webhook retry layer.** `ConnectionNotifier` fires one best-effort outbound HTTP request; it does not queue, retry or back off. Any future retry goes through Oban, not queue logic inside this module.
- **No pre-sync snapshots or data versioning.** `Transfer` rows record what moved and when; target tables are not snapshotted.
- **No diff/merge UI.** Conflict resolution is per table (`:skip | :overwrite | :merge | :append`, field-level merge only); there is no row-level merge or three-way diff view.
- **No DNS-rebinding mitigation on `connection.site_url`.** `validate_base_url/1` rejects RFC1918, loopback, link-local, `localhost`, `.local` and non-`http(s)` URLs at changeset time (host compared lower-cased, without a trailing dot; IPv4-mapped IPv6 included); deployments that legitimately point at internal hosts opt in with `config :phoenix_kit_sync, allow_internal_urls: true`. A public hostname that resolves to an internal IP only at request time is not guarded: resolution-at-request-time is racy and the acute threat is the literal-IP form (cloud metadata is always `169.254.169.254`).
- **No bulk operations across connections.** Approve, suspend and revoke act on one connection at a time.
- **No frame-size limit on the WebSocket client.** `WebSocketClient` is a `WebSockex` process, which reads a frame whole and has no option to bound it, so a sender on the code-based flow decides how much memory one frame takes; the HTTP pull is the capped path (`max_response_bytes`). A bound needs another client library, not a setting.

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
- Every admin LiveView is `use PhoenixKitWeb, :live_view` followed by `use Gettext, backend: PhoenixKitSync.Gettext`; templates never wrap in `LayoutWrapper`. `ApiController` is `use PhoenixKitWeb, :controller`.
- Gettext: the module's own backend `PhoenixKitSync.Gettext`, catalogues in `priv/gettext` (`default.pot`, `en`, `et`, `ru`), macro form only (`gettext/1`, `ngettext/3`). After adding or changing a string: `mix gettext.extract --merge`, fill `et` and `ru`, clear every `#, fuzzy`, and diff the `.po` files for msgstrs the merge changed. Keep every argument a literal string so the extractor and grep can see it; do not refactor `Errors.message/1` into a lookup map. Tab and permission labels are plain strings translated by core through `gettext_backend:`/`gettext_domain:`; `PhoenixKitSync.translatable_labels/0` pins them in the catalogue, so a new tab label goes there too. A status shown to a user goes through `status_label/1` (`Web.ConnectionsLive`, `Web.History`), one literal `gettext` clause per value. `test/phoenix_kit_sync/gettext_catalogue_test.exs` fails on an untranslated string.
- No rendered string names the kit: the catalogue test fails on a msgid containing "PhoenixKit".
- JS hooks: none. `css_sources/0` returns `[:phoenix_kit_sync]` so the host's `:phoenix_kit_css_sources` compiler scans this module's templates for Tailwind classes.
- `enabled?/0` rescues and catches `:exit`, returning `false` (a sandbox-owner exit in a non-DataCase test surfaces as `:exit`, not an exception).
- Activity logging: every state-changing operation in `Connections` calls `log_sync_activity/4`, which persists `sync.connection.<verb>` (created, updated, deleted, approved, suspended, revoked, reactivated; `resource_type: "sync_connection"`, `mode: "manual"`, actor via the `actor_uuid:` opt, which every status function takes; a status the peer reported is logged with no actor and `"reason" => "remote_site"`). `Transfers` logs `sync.transfer.<verb>` (created, approved, denied, cancelled, completed, failed; `resource_type: "sync_transfer"`), on a failed write too (`"db_pending" => true`); a pull's transfer carries the admin who started it (`actor_uuid:` in the pull opts → `initiated_by_uuid`). `SchemaInspector.create_table/3` logs `sync.table.created` (`actor_uuid:` opt; `mode: "auto"` without one). `ImportWorker` logs `sync.import.batch_completed` with `mode: "auto"` and a `session_ref` (a tag derived from the session code; never the code). All three call core's `PhoenixKit.Activity.log/3`, which never raises, so a missing activities table never fails the primary operation. **PII rule:** metadata carries `connection_name`, `direction`, `status`, `reason` (transfers: `table_name`, `direction`, `status`, record counts) and never `site_url` or any token field; the audit feed is visible to other admins.
- Soft-delete: none. Deletes are hard.
- Errors: context functions return `{:error, atom}`; `PhoenixKitSync.Errors.message/1` translates at the UI/API boundary and has a clause for every atom the module emits; unknown atoms fall through to `inspect/1`. Never return free-text error strings from context code, and never put `inspect(reason)` in a flash. A transfer's classified failure is stored as the atom's name and shown through `Errors.transfer_error/1`.
- **SQL identifier safety:** validate every table/column name with `SchemaInspector.valid_identifier?/1` and wrap it in double quotes (`~s["#{name}"]`) before interpolating into raw SQL. Values are always parameterised `$N` binds via `repo.query(sql, [binds])`, never concatenated. Reference: `DataImporter.find_existing/4` and `insert_record/3`. Names that come from the sender are data: the pull refuses a table name or record key that fails `valid_identifier?/1` before any SQL runs (`:invalid_table_name`, `:invalid_column_name`) and writes only columns the local table has; `SchemaInspector.create_table/3` also checks every column name, PK column and type (`valid_column_type?/1`) because DDL takes no bind parameters. On the sender side `ApiController` quotes every table and key name it reads (`quote_ident/1`): unquoted, Postgres folds case, so `"Users"` would read `users` past the connection's table checks. `DataExporter` checks the table, the schema and every `:order_by` name on each of its public functions (`check_names/2`: `:invalid_table_name`, `:invalid_column_name`) before it reads anything; a new entry point there starts with the same call.
- **Tables that are never synced** (`SchemaInspector.excluded_table?/1`, the only place the rule lives): refused on list, export and import, over REST and WebSocket, for token connections and code sessions, even when a connection's `allowed_tables` names them, and never created (`SchemaInspector.create_table/3` checks it itself, before any DDL, so no caller's order matters). Every rule compares lower-cased names, the host's list included: Postgres keeps the case of a quoted name, so `"OBAN_JOBS"` is a table of its own. Three rules, any one excludes: (1) the list — `schema_migrations`, `oban_*`, `pg_*`, `phoenix_kit_sync_connections` and `phoenix_kit_sync_transfers` (the token hash IS the REST credential), `phoenix_kit_settings` (the incoming password and every integration's keys), `phoenix_kit_users_tokens` / `phoenix_kit_user_tokens`, `phoenix_kit_user_oauth_providers`, `phoenix_kit_organization_invitations`, `phoenix_kit_ai_accounts`, `phoenix_kit_ai_endpoints`, `phoenix_kit_buckets`, `phoenix_kit_payment_provider_configs`; (2) the name — any table whose name contains `token`, `secret`, `credential`, `password`, `api_key`, `oauth` or `session`, so a credentials table another module adds is excluded before anyone edits the list; (3) the host's `config :phoenix_kit_sync, excluded_tables: [...]`. A table that holds a credential under a name rule (2) does not catch must be added to the list in the same change that creates it. `phoenix_kit_users` is synced, `hashed_password` included, to any connection whose tables allow it: only connections to fully trusted sites should exist.
- **One authorization.** `Connections.authorize_request/3` decides whether a request under a connection may proceed (sender direction, status, expiry, download and record limits, IP whitelist, allowed hours, download password). The four table-reading REST actions, the socket upgrade (`validate_connection/3`) and every message on an open socket (`SyncWebsock`, which reloads the row first) call it. Never check `status == "active"` or any single restriction at a call site, and never authorize against a connection struct held from an earlier request. A `"receiver"` row authorizes nothing: its token is this site's pass to the peer. Its reading of the two limits only refuses sooner; what holds them is the reservation below.
- **Limits are held by a reservation.** Every answer that carries rows under a connection (`pull-data`, `table-records`, the socket's `request:records`) calls `Connections.reserve_transfer/2` first, reads with `reservation.records` as its limit, then `settle_transfer/3` with the rows it sent, or `cancel_transfer/1` when it sent none. The reservation is one conditional `UPDATE`, so two requests arriving together cannot both take the last download or the last records: rows served never exceed `max_records_total`, downloads never exceed `max_downloads`. A request in flight holds its whole page (`records_downloaded` reads above the limit until it settles, and stays charged if the process dies first). A new action that returns rows reserves the same way; never check a limit on a loaded struct and count afterwards. `table-records` is a download like a pull: an answer free of one would be bounded by the record limit alone.
- Sender-side table authorization: `list-tables`, `pull-data`, `table-schema` and `table-records` filter through `Connection.table_allowed?/2` (the `excluded_tables` blocklist and, when set, the `allowed_tables` allowlist), so a leaked token never grants blanket DB access.
- **Status changes from the peer** go through `Connections.apply_remote_status/2` and nothing else; the rule is `Connection.remote_status_changeset/2`. Only a `"receiver"` row is looked up, and the peer may suspend or revoke an active one and lift a suspension it reported (`metadata["suspended_by_remote"]`, cleared by every local status change). It never activates a pending, revoked or locally suspended row. The sender is the side that notifies: `ConnectionNotifier.notify_status_change/3` sends nothing for a receiver row. `get-connection-status` is a read: no request from the peer activates a pending sender row, only this site's admin does (the Approve button).
- **Incoming registrations** (`register-connection`, unauthenticated) are created `pending` unless the mode is `auto_accept` or `require_password` matched; pending receiver rows are capped (`max_pending_incoming`, default 50), and the duplicate check, the cap and the insert run under one advisory lock (`Connections.register_incoming/2`), so never count-then-insert outside it; a site is one row however its URL is spelled (`Connection.normalize_site_url/1`, the only place the rule lives: rows keep the spelling they were given, and registration and `Connections.find_by_site_url*` compare normal forms); their `site_url` is never contacted (`ConnectionsLive.Status` fetches for active rows only), and the sync page refuses a receiver row that is not active.
- **Client address** comes from core's `PhoenixKit.Utils.IpAddress.client_address/1` (the controller's `client_ip/1`, the plug's `get_remote_ip/1`). Never read `x-forwarded-for` here: its first hop is the client's to choose.
- Counters (`downloads_used`, `records_downloaded`, totals) are incremented in the database (`reserve_transfer/2` and `settle_transfer/3`; `record_transfer/2` for a caller with nothing to limit), never written back from a loaded struct.
- Session codes come from `:crypto.strong_rand_bytes/1` and are claimed once through `SessionStore.claim/2` (serialised in the store's process; `merge/2` for later updates). That a code was claimed is kept in the store's own claims table, apart from the session map, so no status written later frees it; never decide "used" from `session.status`. Only a `:send` session's code opens a socket (`SocketPlug`, `SyncSocket`): nothing in the module creates a `:receive` session, and its owner asked for no rows to leave the site.
- **Credentials stay out of logs, jobs and the activity log**: a session code, a token, a token hash and a download password. The topic of a socket frame is `"transfer:" <> code`, so it is not logged either; the connection info `SocketPlug` hands on has no query string; `ImportWorker` keeps `session_ref`, not the code. `Routes.generate/1` declares every route with `log: false`, because the router's line for a request prints its parameters and the host's `:filter_parameters` does not name `auth_token_hash`, `code` or `token`: keep it on any route added there. Never `inspect/1` a params map, a socket state or a connection-info map into a log line. `test/integration/secrets_in_logs_test.exs` drives each path and reads the log.
- Bulk pull paging: `pull-data` reads in primary-key order and continues by keyset (`PhoenixKitSync.PullCursor`: `after` in, `next_after`/`cursor`/`has_more` out, `truncated` kept for receivers without paging). The cursor is a `Phoenix.Token` signed for one connection, table and position, good for ten minutes; only a request carrying it for that exact position is a continuation that costs no new download (a replay inside the window is free of a download too, never of its records: `records_downloaded` and the record limit count every page). `SyncWebsock` decides the same from its own state (`pages`: the position and the offset each table's page before ended on, good for ten minutes), never from what the peer says about its request. Never page with OFFSET over an unordered read: a table without a primary key is refused (`:no_primary_key`) by `ApiController` and `DataExporter`. The WebSocket and channel `request:records` continue the same way without the signed cursor (the socket is already authorized per message): `DataExporter.fetch_page/2` answers `next_after`, the receiver sends it back as `after` beside its `offset`, and the offset decides only when no `after` came, which is what keeps either side working against a peer from before positions. `next_after` is added to a reply, never sent as null. `PullCursor` is the only cursor implementation: a key type joins `@casts` only if its text reads back as exactly the value and `ORDER BY` and the row comparison order it alike; what `next_after/2` issues, `from_params/1` and `where/4` accept (one cap, `max_value_bytes/0`; a longer key value answers `{:too_long, type}`, which the sender names like a key type), so a new `to_text` clause comes with its `valid_value?` one; a cut answer on any other key carries `unsupported_key_type`, which the receiver shows (`Errors.message({:truncated_key_type, type})`). Loops that follow a peer's pages stop on a repeated page and at a cap (`ConnectionNotifier`, `Client`, `Web.Receiver`).
- Tables without a primary key over the socket: `DataExporter` (the one reader behind `SyncChannel`, `SyncWebsock` and `Client`) has no order to page a keyless table in, so it serves it only when it fits in one page: it reads `limit + 1` rows, answers `{:error, :no_primary_key}` when there are more than `limit`, and otherwise the rows past `:offset` (so the page after the last is empty and a reader that pages until an empty answer ends). A position (`:after`) is refused. `pull-data` and `table-records` keep refusing every keyless table or view, as does the pulling side for a keyless local table (every repeat pull would insert the same rows again), so a keyless table moves only over the socket.
- **Download password on the pulling side**: every REST request to a sender takes `password:` in its opts (`fetch_sender_tables/2`, `fetch_table_schema/3`, `fetch_table_records/3`, `pull_table_data/3`, `pull_table_data_with_remap/4`) and puts it in the body. The sync page asks for it on `:invalid_password` and holds it in the `:sync_password` assign only: never persist it, log it, flash it or put it in activity metadata, and keep the form field named `password` so the parameter filter hides it in the event log.
- Outbound HTTP goes through `ConnectionNotifier.make_http_request/3` / `make_get_request/2`, which cap the response size by endpoint: `max_response_bytes` for a page of records (`pull-data`, `table-records`), 16 MiB or that value when lower for `list-tables` and `table-schema`, 1 MiB for the rest. Do not call Finch directly. A successful answer is taken only in its shape (`tables` and `records` a list of objects, `data` a list): anything else is `:invalid_response`, never a term handed to `Enum`.
- A page of records from a socket is a list of maps or a failed request (`WebSocketClient` answers `{:request_error, {:records, table}, :invalid_response}`): never filter a peer's page, because the receiver advances its offset by what arrived.
- PubSub: `Connections` broadcasts on `PhoenixKit.Config.pubsub_server()` under `Connections.pubsub_topic/0` (`"sync:connections"`): `{:connection_created, uuid}`, `{:connection_updated, uuid}`, `{:connection_status_changed, uuid, status}`, `{:connection_deleted, uuid}`. `Transfers` broadcasts `{:transfer_changed, uuid}` under `Transfers.pubsub_topic/0` (`"sync:transfers"`). Subscribe via the function, not the literal, and before the first read; never add duplicate broadcasts in controllers or LiveViews. All three admin LiveViews subscribe.
- Task supervision: async work in LiveViews is either `Task.start_link/1` (render-only fetches that should die with the LiveView) or `PhoenixKitSync.AsyncTasks.notify_remote_async/1` (`Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, ..., restart: :temporary)`, for notifications that must complete after a DB commit even if the admin closes the tab; linked to the caller when that supervisor is not running). Bare `Task.start/1` is forbidden.
- Oban: batch imports go through `Workers.ImportWorker` (queue `:sync`, `max_attempts: 3`); the host must add `sync` to its Oban queues. Never spawn bare Tasks for import work.
- `Connection.ip_allowed?/2` returns `true` for both `[]` and `nil` whitelists, matching the 1-arity form, so callers can pass a real client IP without special-casing an empty whitelist.
- Self-connection protection: `Connections.create_connection/1` rejects `"sender"` connections to the site's own URL (scheme, port and case normalised). Receivers (API-created) are always allowed.
- Site identity: `ConnectionNotifier.get_our_site_url/0` reads core's `site_url` setting, then `config :phoenix_kit, :public_url`, then the dynamic base URL. `remote_url_prefix/0` mirrors the local URL prefix unless `config :phoenix_kit_sync, remote_url_prefix:` overrides it; the value is normalised (leading slash ensured, trailing slash stripped, `""`/`"/"` collapse to no prefix).
- Values are read by the target column's type, never by their shape, on both import paths: `ConnectionNotifier.Prepare.value/4` and `key_value/2` (HTTP pull, lookups included) and `DataImporter.prepare_typed_value/2` (WebSocket). A string becomes a date/time only in a date/time column and a `Decimal`/float only in a numeric one; a map is the base64 wrapper of bytes only in a `bytea` or `uuid` column (and in elements of such an array), and in a `json`/`jsonb` column an object of that shape is the value; `"2026-01-01"` in a `text`, `varchar`, `citext` or enum column stays text. A new value conversion takes the column type as an argument. Preparation is per record and never raises: an unreadable value is that record's error.
- Exported values by column type: `DataExporter` writes a `uuid` column as its canonical text and any other non-UTF-8 bytes (`bytea`) as `%{"__phoenix_kit_binary__" => base64}`, the same wrapper the HTTP API uses; `json`/`jsonb` go as their decoded term. `DataImporter` reads them back by the target column's type from the schema it loads, never by the value's shape: the wrapper becomes bytes only in `bytea`/`uuid` columns, a uuid's text becomes 16 bytes only in a `uuid` column, a `numeric` string (digits or scientific form, past decimal128's 34 digits too, up to the exporter's 6178 digits and a scale of 16383; beyond that the record fails) becomes `Decimal`, `bytea` text stays bytes, a string in a `text`/`varchar`/`char` column stays a string even when it looks like a date or a time, and `json`/`jsonb` values go to Postgrex as is. An array column (`ColumnInfo.type` `"ARRAY"`, `element_type` looked up in `pg_type` from the column's `udt_name`, so a domain over an array counts too) travels as a JSON list whose elements follow the same rules by element type on both sides, at every depth of a multi-dimensional array, on every path: `DataExporter.serialize_array/2` writes it (the REST `pull-data` and `table-records` call it for array columns) and `DataImporter.prepare_array/2` reads it (`Prepare.value/4` calls it for a column typed `{:array, element_type}`), so there is one implementation of each; a JSON-array element of a `json`/`jsonb` array is passed pre-encoded (`Jason.Fragment`) because Postgrex reads a nested list as another dimension, so a multi-dimensional `jsonb[]` comes back one-dimensional. A value Postgrex returns as a struct of its own goes through `PhoenixKitSync.ExtensionTypes` on every path: `interval`, `inet`, `cidr` and `macaddr` travel as text and are read back by column type; any other struct (ranges, geometric types, `tsvector`) is sent as an unsupported marker that fails its record on import. Never let `inspect/1` text stand in for a value.
- Auto-created tables: `SchemaInspector.create_table/3` creates an array column from its `element_type`, only from an allowlist of built-in types and with unbounded elements (the schema carries the element type, not the column's length or precision); a bare `character` element becomes `bpchar[]`, since `character[]` is `character(1)[]`. A `USER-DEFINED` column, or an array whose element type is off the allowlist, refuses the table with `:unsupported_column_type` before any DDL; an array without an element type (older senders send none) is `:invalid_column_type`. The `table-schema` answer carries `element_type` beside `data_type` (from `SchemaInspector.get_schema/2`). Defaults, sequences and most length modifiers are not copied.
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
- A receiver connection is created `pending` by default and under the default incoming mode; a test (or a fixture) that syncs through one needs `"status" => "active"`, or the sync page redirects with "not active" and nothing is requested.
- The module's own tables and `phoenix_kit_settings` are never synced, so they cannot be the table a test exports or pulls: every such call answers `:table_excluded` / 403. Use `PhoenixKitSync.SyncableTable` or a table the test creates.
- The pull cursor is signed with the endpoint's `secret_key_base` through the request's `conn`: a host that rotates the secret, or a second node with a different one, turns the continuation pages of a pull in flight into new downloads (they still answer).

## Architecture

```
lib/phoenix_kit_sync.ex                    # PhoenixKit.Module impl, settings accessors, session + inspection facade
lib/phoenix_kit_sync/
├── connection.ex / connections.ex         # Connection schema + context (CRUD, guards, activity log, PubSub)
├── transfer.ex / transfers.ex             # Transfer schema + context (lifecycle, approval workflow)
├── errors.ex                              # error atom -> gettext string, single translation point
├── schema_inspector.ex                    # DB introspection (tables, columns, FKs, counts); valid_identifier?/1
├── data_exporter.ex                       # paginated (offset or keyset) + streamed export; array serialization
├── data_importer.ex                       # import with conflict strategies; parameterised SQL, batched find_existing
├── connection_notifier.ex (+ /prepare.ex) # HTTP client to the remote site; value/record transformation, FK remap
├── pull_filter.ex                         # precise-pull ID filter: wire format, validation, SQL in the key's type
├── pull_cursor.ex                         # bulk-pull keyset cursor: after/next_after, row-value comparison in the key's types
├── gettext.ex                             # the module's Gettext backend (priv/gettext)
├── session_store.ex                       # ETS + GenServer for code-based sessions (owner monitoring)
├── async_tasks.ex                         # notify_remote_async/1
├── extension_types.ex                     # wire form of interval/inet/cidr/macaddr; marker for types not carried
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

**Settings keys:** `sync_enabled` (boolean), `sync_incoming_mode` (`"auto_accept" | "require_approval" | "require_password" | "deny_all"`, default `"require_approval"`: registrations wait as `pending`), `sync_incoming_password`. Reads core's `site_url` setting.

**App env:** `config :phoenix_kit_sync, allow_internal_urls: boolean` (default `false`), `remote_url_prefix: string` (default: mirror the local prefix), `excluded_tables: [string]` (default `[]`), `max_pending_incoming: integer` (default 50), `max_response_bytes: integer` (default 268 435 456; a page of records, and the ceiling of the 16 MiB table-list and schema cap). Falls back to `config :phoenix_kit, :public_url` for the site URL.

**Permissions:** `"sync"` (from `permission_metadata/0`); no sub-permissions.

**PubSub:** topics `"sync:connections"` (`Connections.pubsub_topic/0`) and `"sync:transfers"` (`Transfers.pubsub_topic/0`), events listed under Conventions.

**Supervision:** `children/0` starts `SessionStore`.

**API endpoints** (all under the configured URL prefix, default `/phoenix_kit`):

| Method | Path | Handler | Auth |
|--------|------|---------|------|
| POST | `/sync/api/register-connection` | Register incoming connection, `pending` unless the mode accepts it | Module enabled + incoming mode not `deny_all` + password when required + pending cap |
| POST | `/sync/api/delete-connection` | Delete a connection | Module enabled + `sender_url` and `auth_token_hash` match a connection |
| POST | `/sync/api/verify-connection` | Verify connection exists | Module enabled + `sender_url` and `auth_token_hash` match |
| POST | `/sync/api/update-status` | Mirror the sender's status onto the receiver row | Module enabled + `sender_url` and `auth_token_hash` match a `receiver` connection + `Connection.remote_status_changeset/2` |
| POST | `/sync/api/get-connection-status` | Query connection status; a read, changes nothing | Module enabled + `auth_token_hash` matches a sender connection (`receiver_url` is logged, not matched) |
| POST | `/sync/api/list-tables` | List available tables (`include_checksums: false` skips the md5) | Token hash + `authorize_request/3`; filtered by `table_allowed?/2` |
| POST | `/sync/api/pull-data` | Pull table data in key order, at most `max_records_per_request` rows; optional `ids` / `id_start` / `id_end` filter, answered with `"filtered": true`; `after` + `cursor` continue; answers `has_more`, and `truncated` / `next_after` / `cursor` when rows are left (`unsupported_key_type` in place of the last two for a key with no cursor) | Token hash + `authorize_request/3` + table allowed |
| POST | `/sync/api/table-schema` | Get table schema (with `element_type`) | Token hash + `authorize_request/3` + table allowed |
| POST | `/sync/api/table-records` | Get table records (`limit` up to 100, `offset`, the pull filter); one download and its rows per answer | Token hash + `authorize_request/3` + table allowed |
| GET | `/sync/api/status` | Check module status | None |
| WS | `/sync/websocket` | WebSocket sync protocol; `request:records` pages by `offset` or by `after` (the reply's `next_after`); the pages of one read are one download | `?code=` (a `:send` session's, claimed once) or `?token=` (+ `?password=`; `authorize_request/3` at upgrade and per message) |

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
- `StubRemote`: a canned sender behind `Test.Router`'s `/stub-remote` forward, answering `list-tables`, `pull-data` and `table-schema` from `put_tables/1` / `put_data/2` / `put_schema/2` (app env, so `async: false`); `put_response_extra/2` adds fields such as `"filtered"` to a pull-data answer, `put_page_size/2` makes it page by `"id"` with cursors, and `last_pull_body/1` / `pull_bodies/1` / `pull_count/1` show what the receiver sent.
- `SyncableTable`: a real, empty, plain table (`name/0`, `insert!/1`) for tests that list, export or pull one. Receiver-side pull tests use it as the connection's `site_url` because the real `ApiController` reads the same DB the receiver writes to. It sends values as given; a uuid column goes on the wire as the sender serialises it, `%{"__phoenix_kit_binary__" => base64}`.
- `TestActor.uuid/0`: a real registered user for actor FKs. `ActivityLogAssertions.assert_activity_logged/2`: exactly one activity row for an action, with `:resource_uuid`, `:actor_uuid`, `:metadata_has` filters.
- `core_pin_conformance_test.exs` asserts the `:phoenix_kit` floor (2.13.6, see Landmines) and that the upper bound still admits every later 2.x — a requirement pinned to one minor breaks `mix deps.get` for hosts.
- Authorization is tested as a product, and a new restriction or entry point joins it: `test/integration/remote_authorization_test.exs` crosses every restriction with every REST action, the socket upgrade and an open socket, and every {status, requested status, direction} for `update-status`. `pull_cursor_sender_test.exs` walks a table of every supported key type page by page; `pull_value_shapes_test.exs` crosses column types with value shapes on all three import paths; `http_array_values_test.exs` crosses array element types with array shapes through the real `pull-data` action and the real pull; `ws_keyset_paging_test.exs` covers `request:records` by position against peers with and without it; `extension_types_round_trip_test.exs` crosses the struct-valued column types with both protocols; `register_connection_test.exs` holds the table of URL spellings and races registrations on connections outside the sandbox (it deletes what it commits); `transfer_limits_test.exs` reads a table through every action that serves rows against both limits, and races reservations the same way; `untrusted_names_and_shapes_test.exs` holds the spellings of never-synced names, the names outside the identifier rule on every `DataExporter` function, and the malformed answers of each endpoint and socket event; `secrets_in_logs_test.exs` joins a real socket and mounts `Routes.generate/1` in a router of its own. A new key type or element type joins the matching table.

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
- `Web.Sender`, `Web.Receiver` and `Web.Receiver.Helpers` still carry unwrapped template strings; wrap them when the code-based flow gets a route.
- `list-tables` computes an exact count and (unless the receiver opts out) an md5 of every allowed table on each call; a short-lived cache would spare a busy sender.
- A status badge's translated label needs core 2.41.1 (`status_badge`'s `label` attr); below that the badge shows core's English label.
