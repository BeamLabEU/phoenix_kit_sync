# PhoenixKitSync

Peer-to-peer data sync module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Provides bidirectional data synchronization between PhoenixKit instances —
sync between dev and prod, dev and dev, or different websites entirely.

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_sync, "~> 0.2"}
```

The module is auto-discovered via PhoenixKit's beam scanning — no additional
configuration needed. Enable it from the admin dashboard under Modules.

## Architecture

### Automatic Cross-Site Registration

The module uses **permanent connections** with automatic cross-site registration:

1. **Sender creates a connection** pointing to a remote site's URL
2. **System automatically notifies** the remote site via API
3. **Remote site registers the connection** based on their incoming settings:
   - **Auto Accept**: Connection activates immediately
   - **Require Approval** (the default): Connection is created `pending`
     and does nothing until an admin of that site approves it
   - **Require Password**: Only accepts with the correct password, then
     activates
   - **Deny All**: Rejects the connection request
4. **Both sites have matching connection records** for data sync
5. **All transfers are tracked** in the history with full audit trail

### Connection Types

- **Sender**: "I allow this remote site to pull data from me"
- **Receiver**: "I can pull data from this remote site" (created via API)

When you create a sender connection, the remote site receives a corresponding
receiver connection. Only a sender connection grants access: its token is
what the remote site presents to read your tables. A receiver connection is
this site's own pass to the other site's data and gives that site nothing here.

## Features

- **Ephemeral Code-Based Transfers**: One-time manual sync with 8-character secure codes
- **Permanent Token-Based Connections**: Recurring sync with full access controls
- **Token-Based Authentication**: Secure tokens, hashed in database, shown only once
- **Access Controls**: Allowed/excluded tables, download limits, record limits
- **Security Features**: IP whitelist, time-of-day restrictions, expiration dates, download password
- **Conflict Resolution**: skip, overwrite, merge, append strategies
- **Transfer Tracking**: Full history with statistics and approval workflow
- **Audit Trail**: Track who created, approved, suspended, or revoked connections
- **Real-Time Progress**: Live tracking of sync operations
- **Background Import**: Async processing via Oban workers
- **Cross-Site Protocol**: HTTP API + WebSocket for data transfer
- **Activity Audit**: Every connection mutation (create, approve, suspend, revoke, reactivate, delete, token rotate) and every transfer mutation (create, complete, fail, cancel, approve, deny) writes a `sync.<resource>.<verb>` row to `phoenix_kit_activities` with the actor's UUID — visible in the core admin Activity feed
- **Centralised error translation**: Context functions return `{:error, :atom}` tuples; UI / API layers translate via `PhoenixKitSync.Errors.message/1`, which dispatches to gettext-wrapped strings
- **Translations**: The module has its own Gettext backend (`PhoenixKitSync.Gettext`, `priv/gettext`) with English, Estonian and Russian

## Connection Settings

### Sender-Side Controls

These settings are checked on every request the remote site makes with the
connection's token: each REST call (`list-tables`, `pull-data`,
`table-schema`, `table-records`), the WebSocket upgrade, and every message
on an open socket. One function decides
(`PhoenixKitSync.Connections.authorize_request/3`), and it reads the
connection as it is in the database at that moment, so a change made while a
socket is open takes effect on its next message.

| Setting | Enforced | Description |
|---------|----------|-------------|
| **Allowed Tables** | Yes | Whitelist of tables the receiver can access |
| **Excluded Tables** | Yes | Blacklist of tables to hide from receiver |
| **Max Downloads** | Yes | Total pulls. A table read page by page is one pull, over REST (with the sender's cursor) and on one WebSocket (a request for exactly the position, or the offset, the page before ended on, within ten minutes). Every nonempty `table-records` answer is a pull of its own: the receiving site's sync page asks for one only when its admin clicks "Preview rows", never on opening the page, selecting a table or refreshing |
| **Max Records Total** | Yes | Total records that can be downloaded, by `pull-data`, `table-records` and the WebSocket alike; a page is cut where the allowance ends |
| **Max Records Per Request** | Yes | Records per page (default: 10,000), set as "Records per request" in the connection form. A larger table is sent in pages |
| **Download Password** | Yes | The request must carry it (`password` in the REST body, `?password=` on the socket). The receiving site's sync page asks its admin for it when the sender refuses a request without one, keeps it for as long as that page is open, and stores it nowhere |
| **IP Whitelist** | Yes | Only the listed client addresses (see "Client address" below) |
| **Allowed Hours** | Yes | Time-of-day window, in UTC (e.g., only 2am-5am) |
| **Expiration Date** | Yes | Requests after `expires_at` are refused |
| **Requests per minute** | Yes | `rate_limit_requests_per_minute` (default 600; `0` is no limit). Counted: each REST action, the socket upgrade and each `request:*` message on an open socket (not the join or heartbeats), once the request has passed every other check; a wrong download password still counts, so guessing it is bounded too. Over the limit, REST answers `429` with `Retry-After` (seconds until the minute frees) and `"error_code": "rate_limited"`, the upgrade `429` with `Retry-After`, and an open socket `response:error` with `"error_code": "rate_limited"` and `retry_after`. The count is per node, in core's rate-limiter backend |
| **Approval Mode** | **No** | `auto_approve` / `require_approval` / `per_table` and **Auto-Approve Tables** are stored and read by nothing: no pull is held for approval, so every mode behaves as `auto_approve`. (The connection itself still needs approving; see "Connection Statuses") |

An answer with no rows returns its reservation and consumes no download.

A sync of N tables of P pages each makes 1 + N × P requests (the table
list, then one `pull-data` per page), plus one `table-schema` per table
opened on the Precise Transfer tab and one `table-records` per preview.
A site with every module has some 200 tables, nearly all of one page, so
the default of 600 a minute lets a full sync through in one minute with
room to spare; a connection set lower is not refused a sync, only slowed.
On a `429` the receiving site waits the `Retry-After` it was given and
sends the same request again (its sync page says "Rate limited by the
sender, retrying in N s"). The value is the sender's, so the receiver
clamps each wait to `rate_limit_max_wait_seconds` (default 60) and gives
up on a request after `rate_limit_wait_budget_seconds` (default 300) of
waiting, which fails that table with `rate_limited`.

Connections saved before the limit was enforced hold 60, the old default
that nothing read: raise it (`Connections.update_connection/2`) for a
connection that syncs many tables at once, or its syncs wait out the
minute every 60 requests.

Both limits are taken with one conditional `UPDATE` before any row is read
(`Connections.reserve_transfer/2`), so requests arriving together cannot
both take the last download or the last records: the rows served under a
connection never exceed **Max Records Total**, and its pulls never exceed
**Max Downloads**. A request holds its whole page against the record limit
until it has answered, so a second request arriving in that moment can be
refused with `record_limit_reached` although rows are left; it is given
them on its next try.

The connection form has the name, the URL and "Records per request". The
download password, the other limits, the requests per minute and the
approval mode are not in it; set them with `Connections.update_connection/2`.
The form never sets a status.

### Connection Statuses

| Status | Description |
|--------|-------------|
| **Pending** | Created, awaiting approval. Grants and uses nothing. A connection made in the form is created pending (the page says so), and only the Approve button on its row activates it: no approval mode, incoming mode or answer from the remote site does |
| **Active** | In use |
| **Suspended** | Temporarily disabled (can be reactivated) |
| **Revoked** | Permanently disabled |
| **Expired** | A valid status that nothing in this module sets. A connection past its expiry date or its limits is refused on every request whatever its status says |

A status changes only on the site that owns the connection (asking for it
with `get-connection-status` is a read and changes nothing), with one
exception: the sender reports its suspensions and revocations
(`update-status`), and the receiving site mirrors them onto its **receiver**
connection. The remote site can suspend or revoke an active receiver
connection and lift a suspension it reported itself. It cannot activate a
pending, revoked or locally suspended connection, and it cannot touch a
sender connection at all.

## Incoming Connection Settings

Control how your site handles connection requests from other sites:

| Mode | Behavior |
|------|----------|
| **Auto Accept** | Incoming connections activate immediately |
| **Require Approval** | The default. Connections are created pending and need an admin's approval (the Approve button in the Incoming list) |
| **Require Password** | Sender must provide the correct password; the connection then activates |
| **Deny All** | Reject all incoming connection requests |

The registration request is unauthenticated unless the mode asks for a
password. At most 50 registrations wait for approval at a time
(`config :phoenix_kit_sync, max_pending_incoming: 50`); further ones are
answered 429 until some are approved or deleted. A pending connection's site
is never contacted. A sender site has one connection here however its URL is
spelled: `https://Example.com`, `https://example.com/` and
`https://example.com:443` are the same site (scheme and host compared in
lower case, the default port and trailing slashes left out), and a second
registration under any of them is answered 409. The duplicate check, the cap
and the insert are one step, so registrations arriving together cannot get
past either.

## Workflow

### Setting Up a Sender Connection

1. Navigate to the Sync connections page in the admin dashboard
2. Click "New Connection"
3. Enter a name and the remote site's URL
4. Configure access controls (approval mode, tables, limits)
5. Save — the connection is created `pending` and its token generated.
   Approve it (the Approve button on its row) when the remote site may
   start pulling: until then it grants nothing, and nothing the remote site
   does activates it
6. **The remote site is notified automatically!**
   - If successful, the connection appears in their list
   - Based on their settings, it may be auto-approved or pending
7. If notification fails, share the token manually as a fallback

### What Happens on the Remote Site

When you create a sender connection:
- Your site calls `POST {remote_url}/{prefix}/sync/api/register-connection`
- The remote site creates a matching receiver connection
- Based on their incoming mode:
  - **Auto Accept**: Ready to use immediately
  - **Require Approval**: Admin must approve in their connections list
  - **Require Password**: You need to provide their password
  - **Deny All**: Connection is rejected

### Choosing Tables to Pull

- **Primary keys decide how a table is imported.** With a single-column
  key, rows are matched against local ones by key, then by unique columns.
  A row matched by unique columns under another key is remapped, so tables
  that reference it point at the local row (uuid, integer and text keys).
  A composite key such as `(lang, value)` is imported as is: conflicts
  resolve on the whole key. A table with no primary key is not pulled at
  all — the pull reports it as an error, because without a key every
  repeat pull would insert the same rows again.
- **Conflict strategy.** `skip` leaves a matched row alone; `overwrite`
  writes the sender's values onto it; `merge` does the same but keeps the
  local value wherever the sender's is NULL. On the bulk pull, `append`
  inserts unmatched rows under a new key and leaves matched rows alone.
  Unique columns other than the key: on the bulk pull, a row with a new
  single-column key whose unique columns match a local row is that row
  (remapped, then left alone or updated per the strategy). A row that
  would clash with another local row's unique value (a composite key, the
  precise pull, or an update of an existing key) is skipped under skip,
  overwrite and merge.
- **Large tables come in pages.** The sender answers at most its
  connection's `max_records_per_request` rows and says where the rest
  starts; the pull follows until the table ends, for integer, uuid, text,
  `character`, numeric, float, boolean, `bytea`, date, time and timestamp
  keys and composites of them. A sender from before cursors, or a key of
  another type (`time with time zone`, `interval`, an enum, citext),
  answers its first page only: those rows are imported and the table is
  reported as only partly pulled, naming the key type when that is the
  reason. A key value whose text is longer than 8192 bytes is cut the same
  way, and named as such. Such a table is pulled whole once the sender's "Records per
  request" is at least its row count.
- **Array columns** travel as lists whose elements are written and read by
  the array's element type, on the bulk pull as on the WebSocket path: a
  `uuid[]`, `numeric[]`, `date[]`, `timestamptz[]` or `bytea[]` column
  comes back as it was, NULL elements and further dimensions included. A
  JSON `null` element of a `jsonb[]` comes back as NULL, and a
  multi-dimensional `jsonb[]` as one dimension.
- **Column types beyond the basic ones.** `interval`, `inet`, `cidr` and
  `macaddr` values (and arrays of them) come back as they were. Ranges,
  the geometric types (`point`, `box`, `circle`, ...) and `tsvector` are
  not carried: a record holding one is counted as an error on the
  receiving site, with the type named, and the rest of the table is
  imported.
- **Some tables are never synced**, whatever a connection allows: this
  module's own tables, `phoenix_kit_settings`, and the tables that hold
  session tokens, OAuth tokens, invitations and provider keys. See
  "Security Considerations".
- **The table must exist on this site.** A table missing here is reported
  as an error rather than pulled; create it first (Precise Transfer >
  Create Table). Both checks run before anything is requested from the
  sender, so they do not use up its download or record limits.
- **Leave out tables that a database trigger maintains.** Some tables are
  projections that a trigger keeps in step with another table (for example
  a slug lookup table filled by an `AFTER INSERT OR UPDATE` trigger on the
  table that owns the slugs). Pull the source table only: importing it runs
  the trigger on this site and fills the projection here. Pulling the
  projection as well can add rows the source does not have, and the trigger
  may then reject a later write to the source. Sync cannot tell such tables
  apart; leaving them out is the admin's call.
- A table that fails as a whole (sender offline, table missing here, no
  primary key, an import that raised) does not stop the run: its row on
  the results screen shows the reason and the run ends as "completed with
  errors".

## Programmatic API

### Connection Management

```elixir
alias PhoenixKitSync.Connections

# Create a sender connection. The raw token is returned in the third
# tuple element — it's only available at creation time; afterwards only
# the SHA-256 hash is stored.
{:ok, connection, token} =
  Connections.create_connection(%{
    "name" => "Production Backup",
    "direction" => "sender",
    "site_url" => "https://backup.example.com",
    "approval_mode" => "auto_approve",
    "allowed_tables" => ["users", "posts"],
    "max_downloads" => 100,
    "created_by_uuid" => current_user.uuid
  })

# Approve a pending connection. Every status change takes `actor_uuid:`,
# recorded as the actor on its activity-log row
# (`sync.connection.approved`, ...).
{:ok, connection} = Connections.approve_connection(connection, actor_uuid: admin_user_uuid)

# Suspend a connection
{:ok, connection} =
  Connections.suspend_connection(connection, actor_uuid: admin_user_uuid, reason: "Security audit")

# Reactivate a suspended connection
{:ok, connection} = Connections.reactivate_connection(connection, actor_uuid: admin_user_uuid)

# Revoke permanently
{:ok, connection} =
  Connections.revoke_connection(connection, actor_uuid: admin_user_uuid, reason: "No longer needed")

# Rotate the auth token (returns the new raw token, hash stored in DB).
# Logged as `sync.connection.token_regenerated`.
# This is a local, low-level operation: the caller must also replace the
# credential on the peer. The admin UI uses delete + create to reconnect.
{:ok, connection, new_token} = Connections.regenerate_token(connection, actor_uuid: admin_user_uuid)

# Validate a token (a sender connection's; what the socket upgrade does)
case Connections.validate_connection(token, client_ip, password: password) do
  {:ok, connection} -> # Token is valid and the connection may be used now
  {:error, :invalid_token} -> # No sender connection has this token
  {:error, :connection_not_active} -> # Pending, suspended, revoked or expired
  {:error, :connection_expired} -> # Past expires_at
  {:error, :download_limit_reached} -> # Max downloads reached
  {:error, :record_limit_reached} -> # Max records reached
  {:error, :ip_not_allowed} -> # IP not in whitelist
  {:error, :outside_allowed_hours} -> # Outside time window
  {:error, :invalid_password} -> # Download password missing or wrong
end

# The same decision for a connection already loaded (what every REST action
# and every socket message calls)
:ok = Connections.authorize_request(connection, client_ip, password: password)
```

### Transfer Tracking

```elixir
alias PhoenixKitSync.Transfers

# Record a transfer that is already over, in one write
{:ok, transfer} =
  Transfers.record_finished(
    %{
      direction: "send",
      connection_uuid: connection.uuid,
      table_name: "users",
      records_transferred: 150,
      bytes_transferred: 45000
    },
    :completed
  )

# Get transfer history
transfers = Transfers.list_transfers(
  connection_uuid: connection.uuid,
  direction: "send",
  status: "completed"
)

# Get statistics for a connection
stats = Transfers.connection_stats(connection.uuid)
# => %{total_transfers: 25, total_records: 5000, total_bytes: 1500000}
```

### System Control

```elixir
# Enable/disable
PhoenixKitSync.enabled?()
PhoenixKitSync.enable_system()
PhoenixKitSync.disable_system()
PhoenixKitSync.get_config()

# Local database inspection
{:ok, tables} = PhoenixKitSync.list_tables()
{:ok, schema} = PhoenixKitSync.get_schema("users")
{:ok, records} = PhoenixKitSync.export_records("users", limit: 100)

# Import with conflict strategy
{:ok, result} = PhoenixKitSync.import_records("users", records, :skip)
```

### Remote Client

```elixir
alias PhoenixKitSync.Client

{:ok, client} = Client.connect("https://sender.com", "ABC12345")
{:ok, tables} = Client.list_tables(client)
{:ok, result} = Client.transfer(client, "users", strategy: :skip)
Client.disconnect(client)
```

## API Endpoints

Cross-site communication endpoints (under the configured URL prefix):

- `POST /sync/api/register-connection` — Register incoming connection.
  Unauthenticated; the answer's `connection_status` is `"active"` or
  `"pending"` (see "Incoming Connection Settings")
- `POST /sync/api/delete-connection` — Delete a connection
- `POST /sync/api/verify-connection` — Verify connection token
- `POST /sync/api/update-status` — The sender reports a status for the
  receiving site's connection. 409 with
  `"error_code": "status_change_not_allowed"` for a change the remote site
  may not make (see "Connection Statuses"); 404 when no receiver connection
  matches
- `POST /sync/api/get-connection-status` — Query a sender connection's
  status by its token hash. A read: it changes nothing, a pending
  connection included
- `POST /sync/api/list-tables` — List available tables.
  `"include_checksums": false` leaves the per-table content checksum out
- `POST /sync/api/pull-data` — Pull table data. Optional record filter:
  `ids` (up to 1000 key values) or `id_start` / `id_end` (an integer range;
  either bound may be left out), on a table with a single-column key. A
  sender that applied the filter adds `"filtered": true` to the answer; a
  receiver that sent a filter and gets an answer without it (a sender from
  before filters) imports nothing and reports it. Such a sender still
  counts the whole table in its `downloads_used` / `records_downloaded`
  and records the send as completed, although nothing was kept. The
  filter is compared in the key's own type (integer, uuid or text keys;
  a range needs an integer key); a filter the sender cannot apply is a
  400 whose `error_code` says why (`invalid_filter`,
  `unsupported_key_type`, `filter_needs_single_key`). `table-records`
  takes the same filter. This narrows what `table-records` accepted for
  previews: a filter on a table with a composite key or none (a view
  included), an empty `ids` list, or `ids` together with a range is now a
  400, where it used to filter on the first key column or on `id`.
  **Paging.** An answer holds at most the connection's
  `max_records_per_request` rows, in primary-key order, and always says
  `"has_more"`. When rows are left it also carries `"truncated": true`
  (what a receiver from before paging reads), `"next_after"` (the last
  row's key values, as text by column) and `"cursor"`. Send both back as
  `"after"` and `"cursor"` for the next page: the rows strictly after that
  key. With the cursor, signed by the sender for that connection, table and
  position, the page belongs to the pull that produced it; `"after"` alone
  (or with any other cursor) also works but counts as a new download. A
  cursor is good for its own position only and for ten minutes; within
  them the same page can be asked for again without a download being
  counted, and its rows are added to `records_downloaded` each time. A
  receiver that pages sends `"paged": true`, so the sender records each page
  as a completed send rather than a cut one. A table without a primary key
  has no order to page in and is refused
  (`"error_code": "no_primary_key"`); a bad `after` is `invalid_cursor`.
  An answer cut on a key whose type has no cursor carries
  `"unsupported_key_type"` (the type's name) instead of `"next_after"`; so
  does one cut on a key value whose text is over 8192 bytes (`"text value
  over 8192 bytes"`), the longest position a sender issues and accepts.
- `POST /sync/api/table-schema` — Get table schema. Each column carries its
  `element_type` (for an array) beside the `information_schema` names
- `POST /sync/api/table-records` — Get table records (`limit` up to 100,
  `offset`, the `pull-data` filter). Each answer counts as one download and
  its rows as records, and is cut where the record limit ends

The four table endpoints take the connection's download password as
`"password"` and answer 403 with an `error_code` when the connection may not
be used (`connection_not_active`, `connection_expired`,
`download_limit_reached`, `record_limit_reached`, `ip_not_allowed`,
`outside_allowed_hours`, `invalid_password`).
- `GET /sync/api/status` — Check module status

When notifying a remote site, `ConnectionNotifier` prepends the remote's URL
prefix to these paths. By default it mirrors the *local* site's
`PhoenixKit.Config.get_url_prefix/0`, which is correct when both deployments
share the same routing config. If a remote mounts PhoenixKit under a different
prefix than the local site, override it:

```elixir
config :phoenix_kit_sync, remote_url_prefix: "/custom"
```

Use `""` (or `"/"`) when the remote serves the sync API at the root (e.g.
`https://remote.example.com/sync/api/...`).

## Database

Table migrations are currently managed by PhoenixKit's core migration system.
If the tables don't already exist, this package can create them automatically
via `PhoenixKitSync.Migration.up/0`.

See `docs/table_structure.md` in the source repository for full schema documentation.

## Configuration

```elixir
config :phoenix_kit_sync,
  # Let a connection's site_url point at localhost / private addresses
  allow_internal_urls: false,
  # URL prefix of the remote site's sync API (default: this site's own)
  remote_url_prefix: "/phoenix_kit",
  # Tables never synced, on top of the built-in list
  excluded_tables: ["my_app_api_clients"],
  # Registrations that may wait for approval at once
  max_pending_incoming: 50,
  # Largest answer accepted from a remote site for a page of records
  # (pull-data, table-records), in bytes. A table list or a table's schema
  # is capped at 16 MiB (or at this value when it is lower), every other
  # answer at 1 MiB
  max_response_bytes: 268_435_456,
  # Receiving side of a sender's 429: the longest single wait for its
  # Retry-After, and the most one request waits in total, in seconds
  rate_limit_max_wait_seconds: 60,
  rate_limit_wait_budget_seconds: 300
```

## Not Implemented

- **Auto-sync scheduling.** Connections have `auto_sync_enabled`,
  `auto_sync_tables` and `auto_sync_interval_minutes` columns; nothing reads
  them, and the form does not offer them.
- **Per-transfer approval** (see "Sender-Side Controls").

## Security Considerations

- **Token Security**: Tokens are SHA-256 hashed in the database and only shown once on creation; comparisons use `Plug.Crypto.secure_compare/2` to defeat timing attacks. The hash is the credential of the REST API, so the connections table is never synced
- **One authorization for every entry point**: `Connections.authorize_request/3` decides for the REST actions, the WebSocket upgrade and each message on an open socket, against the connection as stored at that moment. Only a `sender` connection authorizes anything
- **Per-connection table authorization**: Even with a valid token, every API endpoint that returns or accepts table data (`list_tables`, `pull_data`, `table_schema`, `table_records`) filters through the connection's `excluded_tables` blocklist and `allowed_tables` allowlist
- **Tables that are never synced**: `schema_migrations`, `oban_*`, `pg_*`, `phoenix_kit_sync_connections`, `phoenix_kit_sync_transfers`, `phoenix_kit_settings`, `phoenix_kit_users_tokens`, `phoenix_kit_user_oauth_providers`, `phoenix_kit_organization_invitations`, `phoenix_kit_ai_accounts`, `phoenix_kit_ai_endpoints`, `phoenix_kit_buckets`, `phoenix_kit_payment_provider_configs`; any table whose name contains `token`, `secret`, `credential`, `password`, `api_key`, `oauth` or `session`; and the host's own `excluded_tables`. Names are compared without regard to case, so a quoted `"PHOENIX_KIT_SETTINGS"` is excluded as well. They are never created from a sender's schema, and are refused on export and import, over REST and WebSocket, for token connections and code sessions alike, even when a connection lists them as allowed. `phoenix_kit_users` **is** synced, password hashes (`hashed_password`) included, to any connection whose tables allow it: create connections only to sites you fully trust, and restrict the table with a connection's allowed or excluded tables where that matters
- **Parameterised SQL with identifier validation**: Every dynamic table / column name interpolated into raw SQL passes through `SchemaInspector.valid_identifier?/1` first; values always go through `$N` parameterised binds. A table whose name is outside that rule (`"customer-data"`) is not listed, read or written on any path
- **Incoming registrations**: created pending unless the mode is `auto_accept` or the incoming password matched; refused outright when `incoming_mode = "require_password"` but no password is configured (no silent bypass)
- **Client address**: the IP whitelist compares against the address core's `PhoenixKit.Utils.IpAddress.client_address/1` reports: `conn.remote_ip`, and a forwarded header only when that address is a proxy on the same box or network (the last `X-Forwarded-For` hop, which the proxy appended). A client-supplied `X-Forwarded-For` is never believed. Behind a proxy on another network, set `remote_ip` with your proxy plug, or the whitelist sees the proxy
- **Session codes**: eight characters from the OS's CSPRNG, never written to the log, to a job or to the activity log (an import job keeps a tag derived from the code, `session_ref`). A code is claimed once for the life of its session, whatever status the session is given afterwards, and only the code of a session opened to send (`create_session(:send)`) opens a socket
- **Credentials in request logs**: the module's routes are declared with `log: false`, so the router's line for a request, which prints its parameters (`auth_token_hash`, `code`, `token`), is not written. Your repo's query log, at debug level, still prints the bind values of every query, the token hash a connection is looked up by among them
- **Outbound requests**: `site_url` is checked against localhost, `.local`, private, loopback and link-local addresses (in any case, with or without a trailing dot, IPv4-mapped IPv6 included) unless `allow_internal_urls` is set; a name that resolves to an internal address only at request time is not caught. The size of every answer is capped (see `max_response_bytes`), and an answer whose table list or records are not a list of objects is refused as an invalid response
- **Audit Trail**: Every state-changing operation lands a row in `phoenix_kit_activities` with `actor_uuid`, `resource_type`, `resource_uuid`, and a PII-safe metadata subset (no `site_url`, no `auth_token_hash`): connection changes (a status the remote site reported is logged with no actor and `reason: "remote_site"`), transfers, and tables created from a sender's schema (`sync.table.created`)

## Troubleshooting

### Connection Issues

1. Verify the token is correct and hasn't been regenerated
2. Check connection status is "active"
3. Verify IP is in whitelist (if configured); behind a reverse proxy, check which address the site sees
4. Check time-of-day restrictions
5. Verify download/record limits haven't been exceeded

### Transfer Failures

1. Check transfer history for error messages
2. Verify table is in allowed tables (if configured)
3. "Only partly pulled": the sender has no cursors (update its sync module), or the table's key type has none; the message then names the type, and the fix is a higher "Records per request" on the sender's connection
4. Review server logs for detailed errors
