defmodule PhoenixKitSync.Connection do
  @moduledoc """
  Schema for DB Sync persistent connections between PhoenixKit instances.

  Connections allow two PhoenixKit sites to establish a permanent relationship
  for data synchronization, replacing ephemeral session codes with token-based
  authentication.

  ## Direction

  Each connection has a direction:
  - `"sender"` - This site will send data (configured on the data-sharing site)
  - `"receiver"` - This site will receive data (configured on the data-receiving site)

  ## Approval Modes (Sender-side)

  - `"auto_approve"` - All transfers are automatically approved
  - `"require_approval"` - Each transfer needs manual approval
  - `"per_table"` - Tables in `auto_approve_tables` don't need approval, others do

  ## Status Flow

  ```
  pending → active → suspended → revoked
                  ↘
                  expired (auto-set when limits exceeded or past expires_at)
  ```

  ## Security Features

  - Token-based authentication (auth_token_hash)
  - Optional download password
  - IP whitelist
  - Time-of-day restrictions
  - Download and record limits
  - Expiration date

  ## Usage Examples

      # Create a sender connection
      {:ok, conn} = Connections.create_connection(%{
        name: "Production Receiver",
        direction: "sender",
        site_url: "https://receiver.example.com",
        approval_mode: "auto_approve"
      })

      # Approve a pending connection
      {:ok, conn} = Connections.approve_connection(conn, admin_user_uuid)

      # Suspend a connection
      {:ok, conn} = Connections.suspend_connection(conn, admin_user_uuid, "Security audit")
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitSync.SchemaInspector
  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_directions ~w(sender receiver)
  @valid_statuses ~w(pending active suspended revoked expired)
  @valid_approval_modes ~w(auto_approve require_approval per_table)
  @valid_conflict_strategies ~w(skip overwrite merge append)

  schema "phoenix_kit_sync_connections" do
    field :name, :string
    field :direction, :string
    field :site_url, :string
    field :auth_token, :string, virtual: true
    field :auth_token_hash, :string
    field :status, :string, default: "pending"

    # Sender-side settings
    field :approval_mode, :string, default: "auto_approve"
    field :allowed_tables, {:array, :string}, default: []
    field :excluded_tables, {:array, :string}, default: []
    field :auto_approve_tables, {:array, :string}, default: []

    # Expiration & limits
    field :expires_at, :utc_datetime
    field :max_downloads, :integer
    field :downloads_used, :integer, default: 0
    field :max_records_total, :integer
    field :records_downloaded, :integer, default: 0

    # Per-request limits
    field :max_records_per_request, :integer, default: 10_000
    field :rate_limit_requests_per_minute, :integer, default: 60

    # Additional security
    field :download_password, :string, virtual: true
    field :download_password_hash, :string
    field :ip_whitelist, {:array, :string}, default: []
    field :allowed_hours_start, :integer
    field :allowed_hours_end, :integer

    # Receiver-side settings
    field :default_conflict_strategy, :string, default: "skip"
    field :auto_sync_enabled, :boolean, default: false
    field :auto_sync_tables, {:array, :string}, default: []
    field :auto_sync_interval_minutes, :integer, default: 60

    # Approval & status tracking
    field :approved_at, :utc_datetime
    field :suspended_at, :utc_datetime
    field :suspended_reason, :string
    field :revoked_at, :utc_datetime
    field :revoked_reason, :string

    # Audit & statistics
    field :last_connected_at, :utc_datetime
    field :last_transfer_at, :utc_datetime
    field :total_transfers, :integer, default: 0
    field :total_records_transferred, :integer, default: 0
    field :total_bytes_transferred, :integer, default: 0

    field :metadata, :map, default: %{}

    belongs_to :approved_by_user, User,
      foreign_key: :approved_by_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :suspended_by_user, User,
      foreign_key: :suspended_by_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :revoked_by_user, User,
      foreign_key: :revoked_by_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :created_by_user, User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for connection creation.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :direction,
      :site_url,
      :auth_token,
      :status,
      :approval_mode,
      :allowed_tables,
      :excluded_tables,
      :auto_approve_tables,
      :expires_at,
      :max_downloads,
      :downloads_used,
      :max_records_total,
      :records_downloaded,
      :max_records_per_request,
      :rate_limit_requests_per_minute,
      :download_password,
      :ip_whitelist,
      :allowed_hours_start,
      :allowed_hours_end,
      :default_conflict_strategy,
      :auto_sync_enabled,
      :auto_sync_tables,
      :auto_sync_interval_minutes,
      :metadata,
      :created_by_uuid
    ])
    |> validate_required([:name, :direction, :site_url])
    |> validate_base_url()
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:approval_mode, @valid_approval_modes)
    |> validate_inclusion(:default_conflict_strategy, @valid_conflict_strategies)
    |> validate_number(:max_records_per_request, greater_than: 0)
    |> validate_number(:rate_limit_requests_per_minute, greater_than: 0)
    |> validate_number(:allowed_hours_start,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 23
    )
    |> validate_number(:allowed_hours_end, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:auto_sync_interval_minutes, greater_than: 0)
    |> unique_constraint([:site_url, :direction],
      name: :phoenix_kit_sync_connections_site_direction_uidx
    )
    |> hash_auth_token()
    |> hash_download_password()
  end

  @doc """
  Changeset for approving a connection.
  """
  @spec approve_changeset(t(), String.t() | map() | nil) :: Ecto.Changeset.t()
  def approve_changeset(connection, admin_user_uuid) do
    connection
    |> change(%{
      status: "active",
      approved_at: UtilsDate.utc_now(),
      approved_by_uuid: resolve_user_uuid(admin_user_uuid)
    })
  end

  @doc """
  Changeset for suspending a connection.
  """
  @spec suspend_changeset(t(), String.t() | map() | nil, String.t() | nil) :: Ecto.Changeset.t()
  def suspend_changeset(connection, admin_user_uuid, reason \\ nil) do
    connection
    |> change(%{
      status: "suspended",
      suspended_at: UtilsDate.utc_now(),
      suspended_by_uuid: resolve_user_uuid(admin_user_uuid),
      suspended_reason: reason
    })
  end

  @doc """
  Changeset for revoking a connection.
  """
  @spec revoke_changeset(t(), String.t() | map() | nil, String.t() | nil) :: Ecto.Changeset.t()
  def revoke_changeset(connection, admin_user_uuid, reason \\ nil) do
    connection
    |> change(%{
      status: "revoked",
      revoked_at: UtilsDate.utc_now(),
      revoked_by_uuid: resolve_user_uuid(admin_user_uuid),
      revoked_reason: reason
    })
  end

  @doc """
  Changeset for reactivating a suspended connection.
  """
  @spec reactivate_changeset(t()) :: Ecto.Changeset.t()
  def reactivate_changeset(connection) do
    connection
    |> change(%{
      status: "active",
      suspended_at: nil,
      suspended_by_uuid: nil,
      suspended_reason: nil
    })
  end

  @doc """
  Changeset for updating connection statistics.
  """
  @spec stats_changeset(t(), map()) :: Ecto.Changeset.t()
  def stats_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :downloads_used,
      :records_downloaded,
      :last_connected_at,
      :last_transfer_at,
      :total_transfers,
      :total_records_transferred,
      :total_bytes_transferred
    ])
  end

  @doc """
  Changeset for updating connection settings.
  """
  @spec settings_changeset(t(), map()) :: Ecto.Changeset.t()
  def settings_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :status,
      :approval_mode,
      :allowed_tables,
      :excluded_tables,
      :auto_approve_tables,
      :expires_at,
      :max_downloads,
      :downloads_used,
      :max_records_total,
      :records_downloaded,
      :max_records_per_request,
      :rate_limit_requests_per_minute,
      :download_password,
      :ip_whitelist,
      :allowed_hours_start,
      :allowed_hours_end,
      :default_conflict_strategy,
      :auto_sync_enabled,
      :auto_sync_tables,
      :auto_sync_interval_minutes,
      :approved_at,
      :suspended_at,
      :suspended_reason,
      :revoked_at,
      :revoked_reason,
      :last_connected_at,
      :last_transfer_at,
      :total_transfers,
      :total_records_transferred,
      :total_bytes_transferred,
      :metadata
    ])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:approval_mode, @valid_approval_modes)
    |> validate_inclusion(:default_conflict_strategy, @valid_conflict_strategies)
    |> validate_number(:max_records_per_request, greater_than: 0)
    |> validate_number(:rate_limit_requests_per_minute, greater_than: 0)
    |> validate_number(:allowed_hours_start,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 23
    )
    |> validate_number(:allowed_hours_end, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:auto_sync_interval_minutes, greater_than: 0)
    |> hash_download_password()
  end

  # Hash auth_token if provided
  defp hash_auth_token(changeset) do
    case get_change(changeset, :auth_token) do
      nil ->
        changeset

      token when is_binary(token) and byte_size(token) > 0 ->
        put_change(changeset, :auth_token_hash, hash_token(token))

      _ ->
        changeset
    end
  end

  # Hash download_password if provided
  defp hash_download_password(changeset) do
    case get_change(changeset, :download_password) do
      nil ->
        changeset

      "" ->
        # Empty string clears the password
        put_change(changeset, :download_password_hash, nil)

      password when is_binary(password) ->
        put_change(changeset, :download_password_hash, hash_token(password))

      _ ->
        changeset
    end
  end

  # Hash a token/password using SHA256
  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies an auth token against the stored hash.
  """
  @spec verify_auth_token(t() | any(), String.t() | any()) :: boolean()
  def verify_auth_token(%__MODULE__{auth_token_hash: hash}, token)
      when is_binary(token) and is_binary(hash) do
    Plug.Crypto.secure_compare(hash_token(token), hash)
  end

  def verify_auth_token(_, _), do: false

  @doc """
  Verifies a download password against the stored hash.
  """
  @spec verify_download_password(t() | any(), String.t() | any()) :: boolean()
  def verify_download_password(%__MODULE__{download_password_hash: nil}, _), do: true
  def verify_download_password(%__MODULE__{download_password_hash: ""}, _), do: true

  def verify_download_password(%__MODULE__{download_password_hash: hash}, password)
      when is_binary(password) and is_binary(hash) do
    Plug.Crypto.secure_compare(hash_token(password), hash)
  end

  def verify_download_password(_, _), do: false

  @doc """
  Generates a secure random token for connection authentication.
  """
  @spec generate_auth_token() :: String.t()
  def generate_auth_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Checks if a connection is currently active and within limits.
  """
  @spec active?(t() | any()) :: boolean()
  def active?(%__MODULE__{status: "active"} = conn) do
    not expired?(conn) and within_download_limits?(conn) and within_record_limits?(conn)
  end

  def active?(_), do: false

  @doc """
  Checks if a connection has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(UtilsDate.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if a connection is within download limits.
  """
  @spec within_download_limits?(t()) :: boolean()
  def within_download_limits?(%__MODULE__{max_downloads: nil}), do: true

  def within_download_limits?(%__MODULE__{max_downloads: max, downloads_used: used}) do
    used < max
  end

  @doc """
  Checks if a connection is within record limits.
  """
  @spec within_record_limits?(t()) :: boolean()
  def within_record_limits?(%__MODULE__{max_records_total: nil}), do: true

  def within_record_limits?(%__MODULE__{max_records_total: max, records_downloaded: downloaded}) do
    downloaded < max
  end

  @doc """
  Checks if current time is within allowed hours.
  """
  @spec within_allowed_hours?(t()) :: boolean()
  def within_allowed_hours?(%__MODULE__{allowed_hours_start: nil}), do: true
  def within_allowed_hours?(%__MODULE__{allowed_hours_end: nil}), do: true

  def within_allowed_hours?(%__MODULE__{
        allowed_hours_start: start_hour,
        allowed_hours_end: end_hour
      }) do
    current_hour = UtilsDate.utc_now().hour

    if start_hour <= end_hour do
      current_hour >= start_hour and current_hour <= end_hour
    else
      # Handles overnight ranges (e.g., 22:00 to 06:00)
      current_hour >= start_hour or current_hour <= end_hour
    end
  end

  @doc """
  Checks if an IP address is in the whitelist.
  """
  @spec ip_allowed?(t()) :: boolean()
  def ip_allowed?(%__MODULE__{ip_whitelist: []}), do: true
  def ip_allowed?(%__MODULE__{ip_whitelist: nil}), do: true

  # An empty / nil whitelist means "allow all" regardless of which arity
  # was called. Without these clauses, the 2-arity catch-all below
  # returns false for any connection that hasn't explicitly opted into a
  # whitelist — exactly the AGENTS.md:140 trap. Callers like SocketPlug
  # pass a real client IP, which previously hit the catch-all and 403'd.
  @spec ip_allowed?(t() | any(), String.t() | any()) :: boolean()
  def ip_allowed?(%__MODULE__{ip_whitelist: []}, _ip), do: true
  def ip_allowed?(%__MODULE__{ip_whitelist: nil}, _ip), do: true

  def ip_allowed?(%__MODULE__{ip_whitelist: whitelist}, ip) when is_binary(ip) do
    ip in whitelist
  end

  def ip_allowed?(_, _), do: false

  @doc """
  Checks if a table requires approval based on the connection's approval mode.
  """
  @spec requires_approval?(t() | any(), String.t() | any()) :: boolean()
  def requires_approval?(%__MODULE__{approval_mode: "auto_approve"}, _table), do: false
  def requires_approval?(%__MODULE__{approval_mode: "require_approval"}, _table), do: true

  def requires_approval?(
        %__MODULE__{approval_mode: "per_table", auto_approve_tables: tables},
        table
      ) do
    table not in tables
  end

  def requires_approval?(_, _), do: true

  @doc """
  Checks if a table is allowed to be accessed.
  """
  @spec table_allowed?(t(), String.t()) :: boolean()
  def table_allowed?(%__MODULE__{excluded_tables: excluded, allowed_tables: allowed}, table) do
    not_excluded =
      is_binary(table) and not SchemaInspector.excluded_table?(table) and table not in excluded

    allowed_or_empty =
      case allowed do
        [] -> true
        _ -> table in allowed
      end

    not_excluded and allowed_or_empty
  end

  # Resolves user UUID from any user identifier
  defp resolve_user_uuid(uuid) when is_binary(uuid), do: uuid
  defp resolve_user_uuid(_), do: nil

  # ===========================================
  # SSRF GUARD ON site_url
  # ===========================================
  #
  # `site_url` flows from this changeset into outbound HTTP/WebSocket
  # via `ConnectionNotifier.build_api_url/1` and
  # `WebSocketClient.build_websocket_url/2`. Without a guard, an admin
  # could create a connection pointing at internal services
  # (`127.0.0.1:6379`, AWS metadata at `169.254.169.254`, intranet
  # admin panels) and exfiltrate via the notifier flow.
  #
  # We default to a strict public-only allowlist; deployments that
  # legitimately point at localhost / RFC1918 (multi-tenant on the
  # same box, internal staging) opt in explicitly via
  # `config :phoenix_kit_sync, allow_internal_urls: true`.
  #
  # DNS-rebinding attacks (host resolves to public IP at validate
  # time, internal IP at request time) are out of scope — would need
  # resolution at request time, which is racy. The acute threat we
  # guard is the literal IP shape (cloud-metadata is always
  # `169.254.169.254` literal).
  defp validate_base_url(changeset) do
    case get_field(changeset, :site_url) do
      nil -> changeset
      "" -> changeset
      url when is_binary(url) -> validate_base_url_string(changeset, url)
      _ -> add_error(changeset, :site_url, "must be a string")
    end
  end

  defp validate_base_url_string(changeset, url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        add_error(changeset, :site_url, "must use http or https scheme")

      is_nil(uri.host) or uri.host == "" ->
        add_error(changeset, :site_url, "must include a hostname")

      Application.get_env(:phoenix_kit_sync, :allow_internal_urls, false) ->
        changeset

      String.ends_with?(uri.host, ".local") ->
        add_error(
          changeset,
          :site_url,
          "cannot point at .local mDNS hostnames (set allow_internal_urls if you need this)"
        )

      uri.host == "localhost" ->
        add_error(
          changeset,
          :site_url,
          "cannot point at localhost (set allow_internal_urls if you need this)"
        )

      internal_host?(uri.host) ->
        add_error(
          changeset,
          :site_url,
          "cannot point at private/loopback/link-local addresses (set allow_internal_urls if you need this)"
        )

      true ->
        changeset
    end
  end

  defp internal_host?(host) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} -> internal_ip?(ip)
      _ -> false
    end
  end

  # IPv4 ranges
  defp internal_ip?({0, _, _, _}), do: true
  defp internal_ip?({10, _, _, _}), do: true
  defp internal_ip?({127, _, _, _}), do: true
  defp internal_ip?({169, 254, _, _}), do: true
  defp internal_ip?({172, b, _, _}) when b in 16..31, do: true
  defp internal_ip?({192, 168, _, _}), do: true
  # IPv6 — loopback `::1`, unspecified `::`, link-local `fe80::/10`,
  # unique-local `fc00::/7`.
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp internal_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp internal_ip?(_), do: false
end
