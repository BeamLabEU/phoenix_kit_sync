defmodule PhoenixKitSync.Connections do
  @moduledoc """
  Context module for managing DB Sync connections.

  Provides CRUD operations and business logic for persistent connections
  between PhoenixKit instances. Connections replace ephemeral session codes
  with permanent token-based authentication.

  ## Connection Directions

  - `"sender"` - This site sends data to other sites
  - `"receiver"` - This site receives data from other sites

  ## Approval Modes (Sender-side)

  Stored and read by nothing: no transfer is held for approval, so every
  mode behaves as `"auto_approve"`. A new connection itself is `"pending"`
  until an admin of this site approves it (`approve_connection/2`).

  - `"auto_approve"` - All transfers are automatically approved
  - `"require_approval"` - Each transfer needs manual approval
  - `"per_table"` - Tables in `auto_approve_tables` don't need approval

  ## Connection Status Flow

  ```
  pending → active → suspended → revoked
  ```

  A connection past `expires_at` or its limits is refused on every request
  (`Connections.authorize_request/3`); no sweep rewrites its stored status.

  ## Usage Examples

      # Create a sender connection
      {:ok, conn, token} = Connections.create_connection(%{
        name: "Production Receiver",
        direction: "sender",
        site_url: "https://receiver.example.com",
        approval_mode: "auto_approve"
      })

      # Validate an incoming connection
      {:ok, conn} = Connections.validate_connection(token, "192.168.1.1")

      # Update connection statistics after transfer
      {:ok, conn} = Connections.record_transfer(conn, %{
        records_count: 100,
        bytes_count: 50000
      })
  """

  import Ecto.Query, warn: false

  use Gettext, backend: PhoenixKitSync.Gettext

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.RateLimit

  @typedoc """
  What `reserve_transfer/2` took from a connection's limits: `records` is
  the number of rows the answer may carry, `held` what is charged to
  `records_downloaded` until the reservation is settled or cancelled.
  """
  @type reservation :: %{
          uuid: UUIDv7.t(),
          downloads: 0 | 1,
          records: pos_integer(),
          held: non_neg_integer()
        }

  # ===========================================
  # PUBSUB BROADCASTING
  # ===========================================

  # Best-effort audit trail. Calls core PhoenixKit.Activity.log/3 with a
  # standardised action string ("sync.connection.<verb>") and the safe
  # subset of connection fields that aren't PII (name, direction, status
  # — NOT the site_url, which may leak internal hostnames to the audit
  # log). Core never raises — a missing activities table or a broken
  # backend is logged there for operators — so a logging failure never
  # crashes the primary operation.
  defp log_sync_activity(action, %Connection{} = connection, opts, extra_metadata \\ %{}) do
    PhoenixKit.Activity.log("sync", "sync.connection.#{action}",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "sync_connection",
      resource_uuid: connection.uuid,
      metadata:
        Map.merge(
          %{
            "connection_name" => connection.name,
            "direction" => connection.direction,
            "status" => connection.status
          },
          extra_metadata
        )
    )

    :ok
  end

  @doc """
  PubSub topic that `Connections` broadcasts on for connection lifecycle
  events (`:connection_created`, `:connection_updated`,
  `:connection_status_changed`, `:connection_deleted`).

  Subscribers should reference this constant rather than the literal
  string so the topic name stays consistent across broadcast and
  subscribe sites.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: "sync:connections"

  defp broadcast(event) do
    case PhoenixKit.Config.pubsub_server() do
      nil -> :ok
      pubsub -> Phoenix.PubSub.broadcast(pubsub, pubsub_topic(), event)
    end
  end

  # ===========================================
  # CRUD OPERATIONS
  # ===========================================

  @doc """
  Creates a new connection with a generated auth token.

  Returns both the connection and the raw auth token (token is only shown once).

  ## Parameters

  - `attrs` - Connection attributes:
    - `:name` (required) - Human-readable name
    - `:direction` (required) - "sender" or "receiver"
    - `:site_url` (required) - URL of the remote site
    - `:approval_mode` - "auto_approve", "require_approval", "per_table"
    - `:created_by` - User ID who created the connection
    - Other optional settings

  ## Examples

      {:ok, conn, token} = Connections.create_connection(%{
        name: "Staging Server",
        direction: "sender",
        site_url: "https://staging.example.com",
        created_by_uuid: current_user.uuid
      })

      # Token is only returned once — store it securely.
  """
  @spec create_connection(map()) ::
          {:ok, Connection.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs) do
    direction = attrs["direction"] || attrs[:direction]
    site_url = attrs["site_url"] || attrs[:site_url]

    if direction == "sender" and self_connection?(site_url) do
      reject_self_connection(attrs, site_url)
    else
      do_insert_connection(attrs)
    end
  end

  defp reject_self_connection(attrs, site_url) do
    Logger.warning(
      "[Sync.Connections] Rejected self-connection " <>
        "| site_url=#{site_url} " <>
        "| our_url=#{ConnectionNotifier.get_our_site_url()}"
    )

    changeset =
      %Connection{}
      |> Connection.changeset(attrs)
      |> Ecto.Changeset.add_error(:site_url, gettext("cannot create a connection to yourself"))
      |> Map.put(:action, :insert)

    {:error, changeset}
  end

  defp do_insert_connection(attrs) do
    with {:ok, connection, token} <- insert_connection(attrs) do
      connection_created(connection)
      {:ok, connection, token}
    end
  end

  defp insert_connection(attrs) do
    repo = RepoHelper.repo()
    token = attrs["auth_token"] || attrs[:auth_token] || Connection.generate_auth_token()
    attrs_with_token = Map.put(attrs, "auth_token", token)

    %Connection{}
    |> Connection.changeset(attrs_with_token)
    |> repo.insert(log: false)
    |> case do
      {:ok, connection} ->
        {:ok, connection, token}

      {:error, changeset} ->
        Logger.warning(
          "[Sync.Connections] Failed to create connection " <>
            "| errors=#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp connection_created(connection) do
    Logger.info(
      "[Sync.Connections] Connection created " <>
        "| uuid=#{connection.uuid} " <>
        "| direction=#{connection.direction} " <>
        "| name=#{inspect(connection.name)} " <>
        "| status=#{connection.status}"
    )

    log_sync_activity("created", connection, actor_uuid: connection.created_by_uuid)
    broadcast({:connection_created, connection.uuid})
  end

  defp self_connection?(nil), do: false

  defp self_connection?(site_url) when is_binary(site_url) do
    our_url = ConnectionNotifier.get_our_site_url()
    urls_match?(site_url, our_url)
  rescue
    _ -> false
  end

  # Compare URLs accounting for default ports (80 for http, 443 for https)
  defp urls_match?(url_a, url_b) do
    parse_url(url_a) == parse_url(url_b)
  end

  defp parse_url(url) when is_binary(url) do
    url = url |> String.trim_trailing("/") |> String.downcase()

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        # Normalize port: nil or default port for scheme → explicit default
        normalized_port =
          case {scheme, port} do
            {"http", nil} -> 80
            {"http", 80} -> 80
            {"https", nil} -> 443
            {"https", 443} -> 443
            {_, nil} -> 80
            {_, p} -> p
          end

        {scheme, host, normalized_port}

      _ ->
        {nil, url, nil}
    end
  end

  @doc """
  Gets a connection by UUID.

  Accepts:
  - UUID string: `get_connection("01234567-89ab-cdef-0123-456789abcdef")`
  """
  @spec get_connection(term()) :: Connection.t() | nil
  def get_connection(id) when is_binary(id) do
    repo = RepoHelper.repo()

    if UUIDUtils.valid?(id) do
      repo.get_by(Connection, uuid: id)
    else
      nil
    end
  end

  def get_connection(_), do: nil

  @doc """
  Gets a connection by UUID, raising if not found.

  Accepts same inputs as `get_connection/1`.
  """
  @spec get_connection!(String.t()) :: Connection.t()
  def get_connection!(id) do
    case get_connection(id) do
      nil -> raise Ecto.NoResultsError, queryable: Connection
      connection -> connection
    end
  end

  @doc """
  Lists all connections with optional filters.

  ## Options

  - `:direction` - Filter by direction ("sender" or "receiver")
  - `:status` - Filter by status
  - `:limit` - Maximum results
  - `:offset` - Number of results to skip
  - `:preload` - Associations to preload

  ## Examples

      connections = Connections.list_connections(direction: "sender", status: "active")
  """
  @spec list_connections(keyword()) :: [Connection.t()]
  def list_connections(opts \\ []) do
    repo = RepoHelper.repo()

    Connection
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> order_by([c], desc: c.inserted_at)
    |> maybe_preload(opts[:preload])
    |> repo.all()
  end

  @doc """
  Counts connections with optional filters.

  ## Options

  - `:direction` - Filter by direction
  - `:status` - Filter by status
  """
  @spec count_connections(keyword()) :: non_neg_integer()
  def count_connections(opts \\ []) do
    repo = RepoHelper.repo()

    Connection
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> repo.aggregate(:count)
  end

  @doc """
  Updates a connection's settings.

  ## Examples

      {:ok, conn} = Connections.update_connection(conn, %{
        name: "New Name",
        max_downloads: 100
      })
  """
  @spec update_connection(Connection.t(), map(), keyword()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def update_connection(%Connection{} = connection, attrs, opts \\ []) do
    repo = RepoHelper.repo()

    changeset =
      connection
      |> Connection.settings_changeset(attrs)
      |> guard_settings_status()

    changed_fields = Map.keys(changeset.changes) -- [:download_password, :auth_token]

    changeset
    |> repo.update(stale_error_field: :status, log: false)
    |> tap(fn
      {:ok, updated} ->
        broadcast_connection_update(connection, updated, changed_fields)

        # No-op save (form submit with all values matching current row):
        # skip the audit row too. Without this guard the feed accrues
        # `"updated"` rows whose `changed_fields` is `[]` — pure noise
        # that dilutes signal in incident forensics.
        if changed_fields != [] do
          log_sync_activity("updated", updated, opts, %{
            "changed_fields" => Enum.map(changed_fields, &to_string/1)
          })
        end

      {:error, changeset} ->
        Logger.warning(
          "[Sync.Connections] Failed to update connection " <>
            "| uuid=#{connection.uuid} " <>
            "| errors=#{inspect(changeset.errors)}"
        )

        log_sync_activity("updated", connection, opts, %{
          "changed_fields" => Enum.map(changed_fields, &to_string/1),
          "db_pending" => true
        })
    end)
  end

  defp guard_settings_status(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :status) do
      {:ok, status} -> guard_settings_transition(changeset, status)
      :error -> changeset
    end
  end

  defp guard_settings_transition(%{data: %{status: current}} = changeset, status)
       when current in ["revoked", "expired"] and status != "revoked" do
    Ecto.Changeset.add_error(
      changeset,
      :status,
      gettext("This connection's current status does not allow that change")
    )
  end

  defp guard_settings_transition(changeset, status) do
    changeset
    |> Ecto.Changeset.delete_change(:status)
    |> Ecto.Changeset.optimistic_lock(:status, fn _ -> status end)
    |> Ecto.Changeset.put_change(:status, status)
  end

  # No changed fields = no-op save. Skip the log line AND the PubSub
  # broadcast; subscribers don't need to re-render their view of something
  # that didn't move. Pre-fix this branch was unreachable because string-
  # keyed attrs always looked "changed" via Map.get-returns-nil.
  defp broadcast_connection_update(_connection, _updated, []), do: :ok

  defp broadcast_connection_update(_connection, updated, changed_fields) do
    Logger.info(
      "[Sync.Connections] Connection updated " <>
        "| uuid=#{updated.uuid} " <>
        "| changed=#{inspect(changed_fields)}"
    )

    if :status in changed_fields or "status" in changed_fields do
      broadcast({:connection_status_changed, updated.uuid, updated.status})
    else
      broadcast({:connection_updated, updated.uuid})
    end
  end

  @doc """
  Deletes a connection.

  ## Examples

      {:ok, conn} = Connections.delete_connection(conn)
  """
  @spec delete_connection(Connection.t()) :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def delete_connection(%Connection{} = connection, opts \\ []) do
    Logger.info(
      "[Sync.Connections] Deleting connection " <>
        "| uuid=#{connection.uuid} " <>
        "| direction=#{connection.direction} " <>
        "| site_url=#{connection.site_url}"
    )

    repo = RepoHelper.repo()

    case repo.delete(connection) do
      {:ok, deleted} ->
        log_sync_activity("deleted", deleted, opts)
        broadcast({:connection_deleted, deleted.uuid})
        {:ok, deleted}

      error ->
        log_sync_activity("deleted", connection, opts, %{"db_pending" => true})
        error
    end
  end

  # ===========================================
  # STATUS MANAGEMENT
  # ===========================================

  @doc """
  Approves a pending connection, making it active.

  ## Options

  - `:actor_uuid` - The user approving the connection

  ## Examples

      {:ok, conn} = Connections.approve_connection(conn, actor_uuid: current_user.uuid)
  """
  @spec approve_connection(Connection.t(), keyword() | String.t() | nil) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def approve_connection(connection, opts \\ [])

  def approve_connection(%Connection{} = connection, opts) when is_list(opts) do
    admin_user_uuid = Keyword.get(opts, :actor_uuid)

    Logger.info(
      "[Sync.Connections] Approving connection " <>
        "| uuid=#{connection.uuid} " <>
        "| approved_by=#{admin_user_uuid}"
    )

    result =
      change_connection_status(connection, ["pending"], fn current ->
        Connection.approve_changeset(current, admin_user_uuid)
      end)

    case result do
      {:ok, updated} ->
        log_sync_activity("approved", updated, actor_uuid: admin_user_uuid)
        broadcast({:connection_status_changed, updated.uuid, "active"})
        {:ok, updated}

      {:error, :status_change_not_allowed} = error ->
        error

      error ->
        log_sync_activity("approved", connection, [actor_uuid: admin_user_uuid], %{
          "db_pending" => true
        })

        error
    end
  end

  # The actor as a bare second argument, the form older callers use.
  def approve_connection(%Connection{} = connection, actor_uuid),
    do: approve_connection(connection, actor_uuid: actor_uuid)

  @doc """
  Suspends an active connection.

  ## Options

  - `:actor_uuid` - The user suspending the connection
  - `:reason` - Optional reason for suspension

  ## Examples

      {:ok, conn} =
        Connections.suspend_connection(conn, actor_uuid: current_user.uuid, reason: "Security audit")
  """
  @spec suspend_connection(Connection.t(), keyword() | String.t() | nil) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def suspend_connection(connection, opts \\ [])

  def suspend_connection(%Connection{} = connection, opts) when is_list(opts) do
    admin_user_uuid = Keyword.get(opts, :actor_uuid)
    reason = Keyword.get(opts, :reason)

    Logger.info(
      "[Sync.Connections] Suspending connection " <>
        "| uuid=#{connection.uuid} " <>
        "| suspended_by=#{admin_user_uuid} " <>
        "| reason=#{inspect(reason)}"
    )

    result =
      change_connection_status(connection, ["active", "suspended"], fn current ->
        Connection.suspend_changeset(current, admin_user_uuid, reason)
      end)

    case result do
      {:ok, updated} ->
        log_sync_activity("suspended", updated, [actor_uuid: admin_user_uuid], %{
          "reason" => reason
        })

        broadcast({:connection_status_changed, updated.uuid, "suspended"})
        {:ok, updated}

      {:error, :status_change_not_allowed} = error ->
        error

      error ->
        log_sync_activity("suspended", connection, [actor_uuid: admin_user_uuid], %{
          "reason" => reason,
          "db_pending" => true
        })

        error
    end
  end

  def suspend_connection(%Connection{} = connection, actor_uuid),
    do: suspend_connection(connection, actor_uuid: actor_uuid)

  @doc false
  @spec suspend_connection(Connection.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def suspend_connection(%Connection{} = connection, actor_uuid, reason),
    do: suspend_connection(connection, actor_uuid: actor_uuid, reason: reason)

  @doc """
  Revokes a connection permanently.

  ## Options

  - `:actor_uuid` - The user revoking the connection
  - `:reason` - Optional reason for revocation

  ## Examples

      {:ok, conn} =
        Connections.revoke_connection(conn, actor_uuid: current_user.uuid, reason: "Compromised")
  """
  @spec revoke_connection(Connection.t(), keyword() | String.t() | nil) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def revoke_connection(connection, opts \\ [])

  def revoke_connection(%Connection{} = connection, opts) when is_list(opts) do
    admin_user_uuid = Keyword.get(opts, :actor_uuid)
    reason = Keyword.get(opts, :reason)

    Logger.info(
      "[Sync.Connections] Revoking connection " <>
        "| uuid=#{connection.uuid} " <>
        "| revoked_by=#{admin_user_uuid} " <>
        "| reason=#{inspect(reason)}"
    )

    result =
      change_connection_status(
        connection,
        ["pending", "active", "suspended", "expired"],
        fn current ->
          Connection.revoke_changeset(current, admin_user_uuid, reason)
        end
      )

    case result do
      {:ok, updated} ->
        log_sync_activity("revoked", updated, [actor_uuid: admin_user_uuid], %{
          "reason" => reason
        })

        broadcast({:connection_status_changed, updated.uuid, "revoked"})
        {:ok, updated}

      {:error, :status_change_not_allowed} = error ->
        error

      error ->
        log_sync_activity("revoked", connection, [actor_uuid: admin_user_uuid], %{
          "reason" => reason,
          "db_pending" => true
        })

        error
    end
  end

  def revoke_connection(%Connection{} = connection, actor_uuid),
    do: revoke_connection(connection, actor_uuid: actor_uuid)

  @doc false
  @spec revoke_connection(Connection.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def revoke_connection(%Connection{} = connection, actor_uuid, reason),
    do: revoke_connection(connection, actor_uuid: actor_uuid, reason: reason)

  @doc """
  Reactivates a suspended connection.

  ## Examples

      {:ok, conn} = Connections.reactivate_connection(conn)
  """
  @spec reactivate_connection(Connection.t(), keyword()) ::
          {:ok, Connection.t()} | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def reactivate_connection(%Connection{} = connection, opts \\ []) do
    Logger.info(
      "[Sync.Connections] Reactivating connection " <>
        "| uuid=#{connection.uuid}"
    )

    result =
      change_connection_status(connection, ["suspended"], fn current ->
        Connection.reactivate_changeset(current)
      end)

    case result do
      {:ok, updated} ->
        log_sync_activity("reactivated", updated, opts)
        broadcast({:connection_status_changed, updated.uuid, "active"})
        {:ok, updated}

      {:error, :status_change_not_allowed} = error ->
        error

      error ->
        log_sync_activity("reactivated", connection, opts, %{"db_pending" => true})
        error
    end
  end

  @doc """
  Applies a status the remote site reported for one of this site's
  connections (the `update-status` API).

  Every move goes through `Connection.remote_status_changeset/2`, the one
  place that says what a peer may change: it can mirror the sender's
  suspension or revocation onto an active `"receiver"` row and lift a
  suspension it reported itself, and nothing else. It cannot activate a
  pending row, undo what an admin here set, or touch a `"sender"` row.

  Returns `{:ok, connection}` (also when the row already has that status)
  or `{:error, :status_change_not_allowed}`.
  """
  @spec apply_remote_status(Connection.t(), String.t()) ::
          {:ok, Connection.t()}
          | {:error, :status_change_not_allowed | Ecto.Changeset.t()}
  def apply_remote_status(%Connection{} = connection, status) do
    result = with_locked_connection(connection, &remote_status_update(&1, status))

    case result do
      {:ok, {:unchanged, current}} ->
        {:ok, current}

      {:ok, {:changed, updated}} ->
        log_sync_activity(remote_status_verb(updated.status), updated, [], %{
          "reason" => "remote_site"
        })

        broadcast({:connection_status_changed, updated.uuid, updated.status})
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  defp remote_status_update(current, status) do
    case Connection.remote_status_changeset(current, status) do
      :unchanged -> {:ok, {:unchanged, current}}
      {:ok, changeset} -> update_remote_status(changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_remote_status(changeset) do
    with {:ok, updated} <- RepoHelper.repo().update(changeset),
         do: {:ok, {:changed, updated}}
  end

  defp change_connection_status(connection, allowed_statuses, changeset_fun) do
    with_locked_connection(connection, fn current ->
      if current.status in allowed_statuses,
        do: RepoHelper.repo().update(changeset_fun.(current)),
        else: {:error, :status_change_not_allowed}
    end)
  end

  # Decide from the locked row, including the remote-suspension marker.
  # Local and remote status writes share this lock; a stale snapshot can
  # never overwrite an admin's revoke. Audit and PubSub happen after commit.
  defp with_locked_connection(connection, fun) do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      current =
        repo.one(from(c in Connection, where: c.uuid == ^connection.uuid, lock: "FOR UPDATE"))

      result = if current, do: fun.(current), else: {:error, :status_change_not_allowed}

      case result do
        {:ok, value} -> value
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp remote_status_verb("active"), do: "reactivated"
  defp remote_status_verb("suspended"), do: "suspended"
  defp remote_status_verb("revoked"), do: "revoked"

  # ===========================================
  # AUTHENTICATION & VALIDATION
  # ===========================================

  @doc """
  Validates an auth token and returns the connection if valid.

  Performs comprehensive validation including:
  - Token verification
  - Status check (must be active)
  - Expiration check
  - Download limits check
  - Record limits check
  - IP whitelist check (if provided)
  - Time-of-day restrictions check
  - Download password check (when the connection has one)

  Only a `"sender"` connection is found: the token of a `"receiver"` row
  authorizes nothing on this site. The checks are `authorize_request/3`'s,
  and `opts` goes to it.

  ## Parameters

  - `token` - The auth token to validate
  - `client_ip` - The client's IP address (optional)

  ## Returns

  - `{:ok, connection}` - Connection is valid and ready to use
  - `{:error, reason}` - Validation failed with reason:
    - `:invalid_token` - Token doesn't match any connection
    - `:connection_not_active` - Connection status is not "active"
    - `:connection_expired` - Connection has expired
    - `:download_limit_reached` - Max downloads exceeded
    - `:record_limit_reached` - Max records exceeded
    - `:ip_not_allowed` - Client IP not in whitelist
    - `:outside_allowed_hours` - Current time outside allowed hours
    - `:invalid_password` - Download password missing or wrong
    - `{:rate_limited, seconds}` - Over the connection's requests per minute

  ## Examples

      case Connections.validate_connection(token, client_ip) do
        {:ok, conn} -> proceed_with_transfer(conn)
        {:error, :connection_expired} -> send_error("Connection has expired")
        {:error, reason} -> send_error("Access denied: \#{reason}")
      end
  """
  @spec validate_connection(String.t(), String.t() | nil, keyword()) ::
          {:ok, Connection.t()} | {:error, atom() | {:rate_limited, pos_integer()}}
  def validate_connection(token, client_ip \\ nil, opts \\ []) do
    with {:ok, connection} <- find_sender_by_token(token),
         :ok <- authorize_request(connection, client_ip, opts) do
      Logger.debug(
        "[Sync.Connections] Token validated " <>
          "| uuid=#{connection.uuid} " <>
          "| direction=#{connection.direction} " <>
          "| client_ip=#{client_ip}"
      )

      {:ok, connection}
    else
      {:error, reason} = error ->
        Logger.warning(
          "[Sync.Connections] Token validation failed " <>
            "| reason=#{refusal_name(reason)} " <>
            "| client_ip=#{client_ip}"
        )

        error
    end
  end

  defp refusal_name({:rate_limited, _seconds}), do: "rate_limited"
  defp refusal_name(reason), do: reason

  @doc """
  Decides whether a request made under `connection` may proceed.

  The one authorization every entry point shares: the REST actions, the
  WebSocket upgrade and each message on an open socket call it with the
  row as it is in the database now, so a restriction holds on all of them
  alike.

  Checks, in order: the row is a `"sender"` one (a `"receiver"` row is this
  site's own pass to the peer's data and gives the peer nothing here),
  status is `"active"`, not past `expires_at`, within
  `max_downloads` and `max_records_total`, the client IP is in the
  whitelist (when one is set), the hour is within the allowed hours, the
  request is within `rate_limit_requests_per_minute`
  (`PhoenixKitSync.RateLimit`; every call that gets this far counts one),
  and the download password matches (when one is set).

  The two limits are read here from the row as loaded, which refuses a
  connection that has used them up before any work is done. It does not
  hold them against requests arriving together: an answer that carries
  rows takes its download and its records with `reserve_transfer/2`.

  ## Parameters

  - `connection` - The connection, freshly loaded
  - `client_ip` - The client's address as a string, or nil when unknown
    (refused when a whitelist is set)
  - `opts`:
    - `:password` - The download password the client supplied
    - `:continuation` - `true` for a further page of a download already
      counted, which is not held to `max_downloads` again
    - `:rate_limit` - `false` for a socket frame that is not a request (the
      join, a heartbeat), which is not counted against the minute

  ## Returns

  `:ok`, or `{:error, reason}` with `:unauthorized`, `:connection_not_active`,
  `:connection_expired`, `:download_limit_reached`, `:record_limit_reached`,
  `:ip_not_allowed`, `:outside_allowed_hours`, `{:rate_limited, seconds}`
  (the seconds until the minute frees) or `:invalid_password`.
  """
  @spec authorize_request(Connection.t(), String.t() | nil, keyword()) ::
          :ok | {:error, atom() | {:rate_limited, pos_integer()}}
  def authorize_request(%Connection{} = connection, client_ip, opts \\ []) do
    with :ok <- check_direction(connection),
         :ok <- check_status(connection),
         :ok <- check_expiration(connection),
         :ok <- check_download_limits(connection, Keyword.get(opts, :continuation, false)),
         :ok <- check_record_limits(connection),
         :ok <- check_ip_whitelist(connection, client_ip),
         :ok <- check_allowed_hours(connection),
         :ok <- check_rate_limit(connection, Keyword.get(opts, :rate_limit, true)) do
      validate_download_password(connection, Keyword.get(opts, :password))
    end
  end

  # Counted after every check a stranger fails (an address off the
  # whitelist cannot spend the peer's minute) and before the password, so
  # guessing it is bounded by the limit too.
  defp check_rate_limit(_connection, false = _count), do: :ok
  defp check_rate_limit(connection, _count), do: RateLimit.check(connection)

  @doc """
  Validates a download password for a connection.

  ## Examples

      case Connections.validate_download_password(conn, password) do
        :ok -> proceed()
        {:error, :invalid_password} -> deny_access()
      end
  """
  @spec validate_download_password(Connection.t(), String.t() | nil) ::
          :ok | {:error, :invalid_password}
  def validate_download_password(%Connection{} = connection, password) do
    if Connection.verify_download_password(connection, password) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  @doc """
  Finds a connection by auth token.

  ## Examples

      {:ok, conn} = Connections.find_by_token(token)
  """
  @spec find_by_token(String.t()) :: {:ok, Connection.t()} | {:error, :invalid_token}
  def find_by_token(token) when is_binary(token) do
    repo = RepoHelper.repo()
    token_hash = hash_token(token)

    case repo.get_by(Connection, [auth_token_hash: token_hash], log: false) do
      nil -> {:error, :invalid_token}
      connection -> {:ok, connection}
    end
  end

  @doc """
  Finds a connection by site URL and direction.

  The URL is compared in its normal form (`Connection.normalize_site_url/1`),
  so the spelling a row was stored with and the spelling asked for need not
  be the same string. When several stored rows are spellings of one site,
  the one stored exactly as asked wins, then the oldest.

  ## Examples

      conn = Connections.find_by_site_url("https://example.com", "sender")
  """
  @spec find_by_site_url(String.t(), String.t()) :: Connection.t() | nil
  def find_by_site_url(site_url, direction) when is_binary(site_url) and is_binary(direction) do
    from(c in Connection, where: c.direction == ^direction)
    |> same_site(site_url)
  end

  @doc """
  Finds a connection by site URL and auth token hash.

  Used to identify a specific connection when the remote site requests
  deletion. The URL is compared as `find_by_site_url/2` compares it.

  ## Examples

      conn = Connections.find_by_site_url_and_hash("https://example.com", "abc123hash")
  """
  @spec find_by_site_url_and_hash(String.t(), String.t()) :: Connection.t() | nil
  def find_by_site_url_and_hash(site_url, auth_token_hash)
      when is_binary(site_url) and is_binary(auth_token_hash) do
    from(c in Connection, where: c.auth_token_hash == ^auth_token_hash)
    |> same_site(site_url)
  end

  @doc """
  Finds a connection by site URL, auth token hash and direction.

  For requests only one side of a connection may make: a status the sender
  reports names this site's `"receiver"` row, never a `"sender"` one. The
  URL is compared as `find_by_site_url/2` compares it.
  """
  @spec find_by_site_url_and_hash(String.t(), String.t(), String.t()) :: Connection.t() | nil
  def find_by_site_url_and_hash(site_url, auth_token_hash, direction)
      when is_binary(site_url) and is_binary(auth_token_hash) and is_binary(direction) do
    from(c in Connection,
      where: c.auth_token_hash == ^auth_token_hash and c.direction == ^direction
    )
    |> same_site(site_url)
  end

  # Rows are stored as their URL was given, so the comparison cannot be an
  # equality in SQL: the rows whose URL names the same host, in any case,
  # are read and compared in their normal form here.
  defp same_site(query, site_url) do
    wanted = Connection.normalize_site_url(site_url)

    host =
      case URI.parse(wanted) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _no_host -> wanted
      end

    pattern = "%" <> String.replace(host, ["\\", "%", "_"], &("\\" <> &1)) <> "%"

    query
    |> where([c], fragment("lower(?) LIKE ?", c.site_url, ^pattern))
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> RepoHelper.repo().all(log: false)
    |> Enum.filter(&(Connection.normalize_site_url(&1.site_url) == wanted))
    |> Enum.sort_by(&(&1.site_url != site_url))
    |> List.first()
  end

  @registration_lock "phoenix_kit_sync:register_connection"

  @doc """
  Creates the receiver connection of an incoming registration, unless this
  site already has one for that sender or holds `:max_pending` pending
  ones.

  The checks and the insert run under one advisory lock, so registrations
  arriving together cannot each pass a check the others are about to make
  false: two for one site make one row, and the pending ones stop at the
  cap. The site is compared by its normal form
  (`Connection.normalize_site_url/1`).

  `attrs` are `create_connection/1`'s, string-keyed. Returns
  `{:error, :connection_exists}`, `{:error, :too_many_pending}` or the
  changeset.
  """
  @spec register_incoming(map(), keyword()) ::
          {:ok, Connection.t()}
          | {:error, :connection_exists | :too_many_pending | Ecto.Changeset.t()}
  def register_incoming(%{"site_url" => site_url} = attrs, opts \\ []) when is_binary(site_url) do
    repo = RepoHelper.repo()
    max_pending = Keyword.get(opts, :max_pending)

    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@registration_lock])

      case do_register_incoming(attrs, site_url, max_pending) do
        {:ok, connection} -> connection
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> tap(fn
      {:ok, connection} -> connection_created(connection)
      {:error, _reason} -> :ok
    end)
  end

  defp do_register_incoming(attrs, site_url, max_pending) do
    cond do
      find_by_site_url(site_url, "receiver") ->
        {:error, :connection_exists}

      attrs["status"] == "pending" and is_integer(max_pending) and
          count_connections(direction: "receiver", status: "pending") >= max_pending ->
        {:error, :too_many_pending}

      true ->
        with {:ok, connection, _token} <- insert_connection(attrs), do: {:ok, connection}
    end
  end

  @doc """
  Finds a connection by auth token hash and direction.

  The auth_token_hash is unique per connection pair, so this can be used
  to find a specific connection without needing the site URL.
  """
  @spec find_by_hash_and_direction(String.t(), String.t()) :: Connection.t() | nil
  def find_by_hash_and_direction(auth_token_hash, direction)
      when is_binary(auth_token_hash) and is_binary(direction) do
    repo = RepoHelper.repo()

    from(c in Connection,
      where: c.auth_token_hash == ^auth_token_hash and c.direction == ^direction
    )
    |> repo.one(log: false)
  end

  # ===========================================
  # TRANSFER TRACKING
  # ===========================================

  @doc """
  Records a transfer and updates connection statistics.

  Adds to the counters without looking at the limits. An answer that
  carries rows to a peer is counted through `reserve_transfer/2` and
  `settle_transfer/3` instead, which is what holds `max_downloads` and
  `max_records_total`.

  ## Parameters

  - `connection` - The connection to update
  - `attrs` - Transfer statistics:
    - `:records_count` - Number of records transferred
    - `:bytes_count` - Bytes transferred
    - `:downloads` - Downloads this counts as (default 1; 0 for a further
      page of a download already counted)

  ## Examples

      {:ok, conn} = Connections.record_transfer(conn, %{
        records_count: 500,
        bytes_count: 250000
      })
  """
  # NOTE: deliberately not activity-logged. record_transfer/2 fires once
  # per sync batch (potentially many times in a single transfer) and is a
  # pure stats-counter update. The Transfers context already creates a
  # `sync_transfer` audit row per batch via Transfers.create_transfer/2,
  # which carries the same accounting info plus direction/status/timing.
  # Logging both would flood the activity feed without adding signal.
  # touch_connected/1 and Transfers.update_progress/2 are excluded for
  # the same reason.
  @spec record_transfer(Connection.t(), map()) :: {:ok, Connection.t()} | {:error, :not_found}
  def record_transfer(%Connection{uuid: uuid}, attrs) do
    repo = RepoHelper.repo()

    records_count = Map.get(attrs, :records_count, 0)
    bytes_count = Map.get(attrs, :bytes_count, 0)
    downloads = Map.get(attrs, :downloads, 1)
    now = UtilsDate.utc_now()

    # Incremented in the database, never from the caller's copy of the row:
    # concurrent requests each add their own count, and a long-lived socket
    # does not write back the numbers it saw when it connected.
    query = from(c in Connection, where: c.uuid == ^uuid, select: c)

    case repo.update_all(query,
           inc: [
             downloads_used: downloads,
             records_downloaded: records_count,
             total_transfers: downloads,
             total_records_transferred: records_count,
             total_bytes_transferred: bytes_count
           ],
           set: [last_connected_at: now, last_transfer_at: now]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Reserves a download and a page of records against the connection's limits.

  The limits are held here and nowhere else: one conditional `UPDATE` adds
  the download and the page only while `max_downloads` and
  `max_records_total` allow, so two requests arriving together cannot both
  take the last download or the last records. `authorize_request/3` reads
  the same limits earlier only to refuse sooner.

  Every answer that carries rows is reserved first, read with the granted
  count as its limit, and then settled (`settle_transfer/3`) with the rows
  it really sent, or cancelled (`cancel_transfer/1`) when it sent none.

  The guarantee: the rows served under a connection never exceed
  `max_records_total`, and the downloads never exceed `max_downloads`. A
  request in flight holds its whole page against the record limit until it
  settles, so `records_downloaded` can read above the limit for that moment
  (a request arriving then is refused), and stays charged if the serving
  process dies before settling.

  ## Parameters

  - `connection` - The connection (only its uuid is read)
  - `attrs`:
    - `:downloads` - `1` for a new download, `0` for a further page of one
      already counted
    - `:records` - The most rows the answer may carry

  ## Returns

  - `{:ok, reservation}` - `reservation.records` is how many rows may be
    sent: `:records`, or what was left of the limit when that is less
  - `{:error, :download_limit_reached | :record_limit_reached | :not_found}`
  """
  @spec reserve_transfer(Connection.t(), %{downloads: 0 | 1, records: pos_integer()}) ::
          {:ok, reservation()}
          | {:error, :download_limit_reached | :record_limit_reached | :not_found}
  def reserve_transfer(%Connection{uuid: uuid}, %{downloads: downloads, records: records})
      when downloads in [0, 1] and is_integer(records) and records > 0 do
    repo = RepoHelper.repo()

    download_allowed =
      if downloads == 0 do
        dynamic(true)
      else
        dynamic([c], is_nil(c.max_downloads) or c.downloads_used < c.max_downloads)
      end

    query =
      from(c in Connection,
        where: c.uuid == ^uuid,
        where: ^download_allowed,
        where: is_nil(c.max_records_total) or c.records_downloaded < c.max_records_total,
        # A connection without a record limit holds nothing against it.
        update: [
          inc: [downloads_used: ^downloads],
          set: [
            records_downloaded:
              fragment(
                "? + CASE WHEN ? IS NULL THEN 0 ELSE ?::bigint END",
                c.records_downloaded,
                c.max_records_total,
                ^records
              )
          ]
        ],
        select: c
      )

    case repo.update_all(query, []) do
      {1, [%Connection{max_records_total: nil}]} ->
        {:ok, %{uuid: uuid, downloads: downloads, records: records, held: 0}}

      {1, [%Connection{max_records_total: max, records_downloaded: now}]} ->
        granted = records - max(now - max, 0)
        {:ok, %{uuid: uuid, downloads: downloads, records: granted, held: records}}

      {0, _} ->
        refused_reservation(repo.get(Connection, uuid), downloads)
    end
  end

  defp refused_reservation(nil, _downloads), do: {:error, :not_found}

  defp refused_reservation(%Connection{} = connection, downloads) do
    if downloads == 1 and not Connection.within_download_limits?(connection) do
      {:error, :download_limit_reached}
    else
      {:error, :record_limit_reached}
    end
  end

  @doc """
  Settles a reservation with what the answer carried.

  Gives back the part of the reserved page that was not sent and adds the
  transfer to the connection's statistics.

  - `served` - Number of rows sent
  - `bytes_count` - Bytes sent (default 0)
  """
  @spec settle_transfer(reservation(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Connection.t()} | {:error, :not_found}
  def settle_transfer(%{uuid: uuid} = reservation, served, bytes_count \\ 0)
      when is_integer(served) and served >= 0 do
    now = UtilsDate.utc_now()

    update_counters(uuid,
      inc: [
        records_downloaded: served - reservation.held,
        total_transfers: reservation.downloads,
        total_records_transferred: served,
        total_bytes_transferred: bytes_count
      ],
      set: [last_connected_at: now, last_transfer_at: now]
    )
  end

  @doc """
  Gives a reservation back whole: the request it was made for sent nothing.
  """
  @spec cancel_transfer(reservation()) :: {:ok, Connection.t()} | {:error, :not_found}
  def cancel_transfer(%{uuid: uuid} = reservation) do
    update_counters(uuid,
      inc: [downloads_used: -reservation.downloads, records_downloaded: -reservation.held]
    )
  end

  defp update_counters(uuid, updates) do
    query = from(c in Connection, where: c.uuid == ^uuid, select: c)

    case RepoHelper.repo().update_all(query, updates) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Updates last connected timestamp.

  ## Examples

      {:ok, conn} = Connections.touch_connected(conn)
  """
  @spec touch_connected(Connection.t()) :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def touch_connected(%Connection{} = connection) do
    repo = RepoHelper.repo()

    connection
    |> Connection.stats_changeset(%{last_connected_at: UtilsDate.utc_now()})
    |> repo.update(log: false)
  end

  # ===========================================
  # ACCESS CONTROL HELPERS
  # ===========================================

  @doc """
  Checks if a table is allowed for this connection.

  Takes into account both `allowed_tables` and `excluded_tables`.

  ## Examples

      Connections.table_allowed?(conn, "users")
      # => true

      Connections.table_allowed?(conn, "secrets")
      # => false
  """
  @spec table_allowed?(Connection.t(), String.t()) :: boolean()
  def table_allowed?(%Connection{} = connection, table_name) do
    Connection.table_allowed?(connection, table_name)
  end

  @doc """
  Gets the remaining download allowance for a connection.

  Returns `:unlimited` if no limit is set.

  ## Examples

      Connections.remaining_downloads(conn)
      # => 45 (if max_downloads: 50, downloads_used: 5)
      # => :unlimited (if max_downloads: nil)
  """
  @spec remaining_downloads(Connection.t()) :: non_neg_integer() | :unlimited
  def remaining_downloads(%Connection{max_downloads: nil}), do: :unlimited

  def remaining_downloads(%Connection{max_downloads: max, downloads_used: used}) do
    max(0, max - used)
  end

  @doc """
  Gets the remaining record allowance for a connection.

  Returns `:unlimited` if no limit is set.

  ## Examples

      Connections.remaining_records(conn)
      # => 9500 (if max_records_total: 10000, records_downloaded: 500)
      # => :unlimited (if max_records_total: nil)
  """
  @spec remaining_records(Connection.t()) :: non_neg_integer() | :unlimited
  def remaining_records(%Connection{max_records_total: nil}), do: :unlimited

  def remaining_records(%Connection{max_records_total: max, records_downloaded: downloaded}) do
    max(0, max - downloaded)
  end

  # ===========================================
  # EXPIRATION & CLEANUP
  # ===========================================

  @doc """
  Gets connections expiring soon (within given hours).

  Useful for sending expiration warnings.

  ## Examples

      expiring = Connections.expiring_soon(24)  # Expiring within 24 hours
  """
  @spec expiring_soon(non_neg_integer()) :: [Connection.t()]
  def expiring_soon(hours \\ 24) do
    repo = RepoHelper.repo()
    now = UtilsDate.utc_now()
    cutoff = DateTime.add(now, hours * 3600, :second)

    from(c in Connection,
      where: c.status == "active",
      where: not is_nil(c.expires_at),
      where: c.expires_at > ^now and c.expires_at <= ^cutoff,
      order_by: [asc: c.expires_at]
    )
    |> repo.all()
  end

  # ===========================================
  # TOKEN MANAGEMENT
  # ===========================================

  @doc """
  Regenerates the auth token for a connection.

  Returns the new raw token (only shown once).

  ## Examples

      {:ok, conn, new_token} = Connections.regenerate_token(conn)
  """
  @spec regenerate_token(Connection.t(), keyword()) ::
          {:ok, Connection.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def regenerate_token(%Connection{} = connection, opts \\ []) do
    repo = RepoHelper.repo()
    new_token = Connection.generate_auth_token()

    connection
    |> Connection.changeset(%{auth_token: new_token})
    |> repo.update(log: false)
    |> case do
      {:ok, updated_connection} ->
        # Token regeneration is a security-sensitive event — log it. The
        # raw token never enters metadata; only the fact that a rotation
        # happened is recorded.
        log_sync_activity("token_regenerated", updated_connection, opts)
        {:ok, updated_connection, new_token}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp filter_by_direction(query, nil), do: query
  defp filter_by_direction(query, direction), do: where(query, [c], c.direction == ^direction)

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [c], c.status == ^status)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  defp check_direction(%Connection{direction: "sender"}), do: :ok
  defp check_direction(%Connection{}), do: {:error, :unauthorized}

  # Both ends of a connection store the same token hash, so on a site that
  # holds the two rows of a pair the token names two of them. Only the
  # sender row answers for incoming requests.
  defp find_sender_by_token(token) when is_binary(token) do
    case find_by_hash_and_direction(hash_token(token), "sender") do
      nil -> {:error, :invalid_token}
      connection -> {:ok, connection}
    end
  end

  defp find_sender_by_token(_token), do: {:error, :invalid_token}

  defp check_status(%Connection{status: "active"}), do: :ok
  defp check_status(_), do: {:error, :connection_not_active}

  defp check_expiration(%Connection{} = connection) do
    if Connection.expired?(connection) do
      {:error, :connection_expired}
    else
      :ok
    end
  end

  defp check_download_limits(%Connection{}, true = _continuation), do: :ok

  defp check_download_limits(%Connection{} = connection, _continuation) do
    if Connection.within_download_limits?(connection) do
      :ok
    else
      {:error, :download_limit_reached}
    end
  end

  defp check_record_limits(%Connection{} = connection) do
    if Connection.within_record_limits?(connection) do
      :ok
    else
      {:error, :record_limit_reached}
    end
  end

  defp check_ip_whitelist(%Connection{} = connection, ip) do
    if Connection.ip_allowed?(connection, ip) do
      :ok
    else
      {:error, :ip_not_allowed}
    end
  end

  defp check_allowed_hours(%Connection{} = connection) do
    if Connection.within_allowed_hours?(connection) do
      :ok
    else
      {:error, :outside_allowed_hours}
    end
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
