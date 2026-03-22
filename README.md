# PhoenixKitSync

Peer-to-peer data sync module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Provides bidirectional data synchronization between PhoenixKit instances —
sync between dev and prod, dev and dev, or different websites entirely.

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_sync, path: "../phoenix_kit_sync"}
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
   - **Require Approval**: Connection appears as pending
   - **Require Password**: Only accepts with correct password
   - **Deny All**: Rejects the connection request
4. **Both sites have matching connection records** for data sync
5. **All transfers are tracked** in the history with full audit trail

### Connection Types

- **Sender**: "I allow this remote site to pull data from me"
- **Receiver**: "I can pull data from this remote site" (auto-created via API)

When you create a sender connection, the remote site automatically receives a corresponding receiver connection.

## Features

- **Ephemeral Code-Based Transfers**: One-time manual sync with 8-character secure codes
- **Permanent Token-Based Connections**: Recurring sync with full access controls
- **Token-Based Authentication**: Secure tokens, hashed in database, shown only once
- **Approval Modes**: Auto-approve, require approval, or per-table approval
- **Access Controls**: Allowed/excluded tables, download limits, record limits
- **Security Features**: IP whitelist, time-of-day restrictions, expiration dates
- **Conflict Resolution**: skip, overwrite, merge, append strategies
- **Transfer Tracking**: Full history with statistics and approval workflow
- **Audit Trail**: Track who created, approved, suspended, or revoked connections
- **Real-Time Progress**: Live tracking of sync operations
- **Background Import**: Async processing via Oban workers
- **Cross-Site Protocol**: HTTP API + WebSocket for data transfer

## Connection Settings

### Sender-Side Controls

| Setting | Description |
|---------|-------------|
| **Approval Mode** | `auto_approve`, `require_approval`, or `per_table` |
| **Allowed Tables** | Whitelist of tables the receiver can access |
| **Excluded Tables** | Blacklist of tables to hide from receiver |
| **Auto-Approve Tables** | Tables that don't need approval (when mode is `per_table`) |
| **Max Downloads** | Limit total number of transfer sessions |
| **Max Records Total** | Limit total records that can be downloaded |
| **Max Records Per Request** | Limit records per single request (default: 10,000) |
| **Rate Limit** | Requests per minute limit (default: 60) |
| **Download Password** | Optional password required for each transfer |
| **IP Whitelist** | Only allow connections from specific IPs |
| **Allowed Hours** | Time-of-day restrictions (e.g., only 2am-5am) |
| **Expiration Date** | Auto-expire the connection after a date |

### Connection Statuses

| Status | Description |
|--------|-------------|
| **Pending** | Just created, awaiting activation |
| **Active** | Ready to accept connections |
| **Suspended** | Temporarily disabled (can be reactivated) |
| **Revoked** | Permanently disabled |
| **Expired** | Auto-expired due to limits or date |

## Incoming Connection Settings

Control how your site handles connection requests from other sites:

| Mode | Behavior |
|------|----------|
| **Auto Accept** | Incoming connections activate immediately |
| **Require Approval** | Connections appear as pending, need manual approval |
| **Require Password** | Sender must provide correct password |
| **Deny All** | Reject all incoming connection requests |

## Workflow

### Setting Up a Sender Connection

1. Navigate to the Sync connections page in the admin dashboard
2. Click "New Connection"
3. Enter a name and the remote site's URL
4. Configure access controls (approval mode, tables, limits)
5. Save — the connection is created and token generated
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

## Programmatic API

### Connection Management

```elixir
alias PhoenixKitSync.Connections

# Create a sender connection
{:ok, connection} = Connections.create_connection(%{
  name: "Production Backup",
  direction: "sender",
  site_url: "https://backup.example.com",
  approval_mode: "auto_approve",
  allowed_tables: ["users", "posts"],
  max_downloads: 100,
  created_by_uuid: current_user.uuid
})

# The token is returned in connection.auth_token (only on create)
token = connection.auth_token

# Approve a pending connection
{:ok, connection} = Connections.approve_connection(connection, admin_user_uuid)

# Suspend a connection
{:ok, connection} = Connections.suspend_connection(connection, admin_user_uuid, "Security audit")

# Reactivate a suspended connection
{:ok, connection} = Connections.reactivate_connection(connection)

# Revoke permanently
{:ok, connection} = Connections.revoke_connection(connection, admin_user_uuid, "No longer needed")

# Validate a token (used by receiver when connecting)
case Connections.validate_connection(token, client_ip) do
  {:ok, connection} -> # Token is valid, connection is active
  {:error, :invalid_token} -> # Token doesn't exist
  {:error, :connection_expired} -> # Expired or revoked
  {:error, :download_limit_reached} -> # Max downloads reached
  {:error, :ip_not_allowed} -> # IP not in whitelist
  {:error, :outside_allowed_hours} -> # Outside time window
end
```

### Transfer Tracking

```elixir
alias PhoenixKitSync.Transfers

# Record a transfer
{:ok, transfer} = Transfers.create_transfer(%{
  direction: "send",
  connection_uuid: connection.uuid,
  table_name: "users",
  records_transferred: 150,
  bytes_transferred: 45000,
  status: "completed"
})

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

- `POST /sync/api/register-connection` — Register incoming connection
- `POST /sync/api/delete-connection` — Delete a connection
- `POST /sync/api/verify-connection` — Verify connection token
- `POST /sync/api/update-status` — Update connection status
- `POST /sync/api/get-connection-status` — Query connection status
- `POST /sync/api/list-tables` — List available tables
- `POST /sync/api/pull-data` — Pull table data
- `POST /sync/api/table-schema` — Get table schema
- `POST /sync/api/table-records` — Get table records
- `GET /sync/api/status` — Check module status

## Database

Table migrations are currently managed by PhoenixKit's core migration system.
If the tables don't already exist, this package can create them automatically
via `PhoenixKitSync.Migration.up/0`.

See [docs/table_structure.md](docs/table_structure.md) for full schema documentation.

## Future Plans

### Auto-Sync Scheduling (Planned)

Connections have fields for auto-sync but the scheduler isn't implemented yet:
- `auto_sync_enabled`: Enable automatic periodic sync
- `auto_sync_tables`: Tables to sync automatically
- `auto_sync_interval_minutes`: How often to sync

## Security Considerations

- **Token Security**: Tokens are hashed in database, only shown once on creation
- **Optional Password**: Additional password can be required per-transfer
- **IP Whitelisting**: Restrict connections to specific IP addresses
- **Time Restrictions**: Allow connections only during specific hours
- **Rate Limiting**: Prevent abuse with request limits
- **Audit Trail**: Full tracking of who did what and when

## Troubleshooting

### Connection Issues

1. Verify the token is correct and hasn't been regenerated
2. Check connection status is "active"
3. Verify IP is in whitelist (if configured)
4. Check time-of-day restrictions
5. Verify download/record limits haven't been exceeded

### Transfer Failures

1. Check transfer history for error messages
2. Verify table is in allowed tables (if configured)
3. Check approval status if approval mode is enabled
4. Review server logs for detailed errors
