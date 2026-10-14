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

  Stored and read by nothing: no transfer is held for approval, so every
  mode behaves as `"auto_approve"`. (Approving the connection itself is
  separate: a new connection is `"pending"` until an admin of this site
  approves it.)

  - `"auto_approve"` - All transfers are automatically approved
  - `"require_approval"` - Each transfer needs manual approval
  - `"per_table"` - Tables in `auto_approve_tables` don't need approval, others do

  ## Status Flow

  ```
  pending → active → suspended → revoked
  ```

  A connection past `expires_at` or its limits is refused on every request
  (`Connections.authorize_request/3`); its stored status stays as it was.
  `"expired"` is a valid status that nothing in this module sets.

  ## Security Features

  Checked on every request by `Connections.authorize_request/3`:

  - Token-based authentication (auth_token_hash)
  - Optional download password
  - IP whitelist
  - Time-of-day restrictions
  - Download and record limits
  - Expiration date
  - Requests per minute (`rate_limit_requests_per_minute`, `0` for no
    limit; `PhoenixKitSync.RateLimit`)

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

  @typedoc """
  A connection row. `auth_token` and `download_password` are virtual: set
  on the way in, stored only as their hashes. A `*_user` association is
  `Ecto.Association.NotLoaded` until preloaded.
  """
  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          direction: String.t() | nil,
          site_url: String.t() | nil,
          auth_token: String.t() | nil,
          auth_token_hash: String.t() | nil,
          status: String.t() | nil,
          approval_mode: String.t() | nil,
          allowed_tables: [String.t()] | nil,
          excluded_tables: [String.t()] | nil,
          auto_approve_tables: [String.t()] | nil,
          expires_at: DateTime.t() | nil,
          max_downloads: integer() | nil,
          downloads_used: integer() | nil,
          max_records_total: integer() | nil,
          records_downloaded: integer() | nil,
          max_records_per_request: integer() | nil,
          rate_limit_requests_per_minute: integer() | nil,
          download_password: String.t() | nil,
          download_password_hash: String.t() | nil,
          ip_whitelist: [String.t()] | nil,
          allowed_hours_start: integer() | nil,
          allowed_hours_end: integer() | nil,
          default_conflict_strategy: String.t() | nil,
          auto_sync_enabled: boolean() | nil,
          auto_sync_tables: [String.t()] | nil,
          auto_sync_interval_minutes: integer() | nil,
          approved_at: DateTime.t() | nil,
          suspended_at: DateTime.t() | nil,
          suspended_reason: String.t() | nil,
          revoked_at: DateTime.t() | nil,
          revoked_reason: String.t() | nil,
          last_connected_at: DateTime.t() | nil,
          last_transfer_at: DateTime.t() | nil,
          total_transfers: integer() | nil,
          total_records_transferred: integer() | nil,
          total_bytes_transferred: integer() | nil,
          metadata: map() | nil,
          approved_by_uuid: UUIDv7.t() | nil,
          approved_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          suspended_by_uuid: UUIDv7.t() | nil,
          suspended_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          revoked_by_uuid: UUIDv7.t() | nil,
          revoked_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          created_by_uuid: UUIDv7.t() | nil,
          created_by_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_directions ~w(sender receiver)
  @valid_statuses ~w(pending active suspended revoked expired)
  @valid_approval_modes ~w(auto_approve require_approval per_table)
  @valid_conflict_strategies ~w(skip overwrite merge append)

  # The column is a 4-byte integer: a larger value would fail the write
  # instead of the changeset.
  @max_records_per_request_limit 2_147_483_647

  @doc """
  The bounds of `max_records_per_request`, the most rows one request is
  answered with: the changesets validate against them and the connection
  form offers them.
  """
  @spec max_records_per_request_range() :: Range.t()
  def max_records_per_request_range, do: 1..@max_records_per_request_limit

  @doc """
  The form two spellings of one site's URL share, for comparing them:
  scheme and host in lower case (the host without a trailing dot), the
  scheme's default port left out, trailing slashes dropped. The path keeps
  its case, and a fragment is ignored.

  Connections store `site_url` as it was given; this is what registration
  and the `Connections.find_by_site_url*` lookups compare, so
  `https://Example.com:443/` and `https://example.com` are one site. Text
  that is not a URL with a scheme and a host is returned trimmed.
  """
  @spec normalize_site_url(String.t()) :: String.t()
  def normalize_site_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)
        port = if uri.port in [nil, URI.default_port(scheme)], do: "", else: ":#{uri.port}"
        userinfo = if uri.userinfo, do: uri.userinfo <> "@", else: ""
        query = if uri.query, do: "?" <> uri.query, else: ""

        scheme <>
          "://" <> userinfo <> normal_host(host) <> port <> normal_path(uri.path) <> query

      _not_a_url ->
        trimmed
    end
  end

  defp normal_host(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    # URI.parse/1 takes the brackets off an IPv6 literal.
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp normal_path(nil), do: ""

  defp normal_path(path), do: String.trim_trailing(path, "/")

  schema "phoenix_kit_sync_connections" do
    field :name, :string
    field :direction, :string
    field :site_url, :string
    field :auth_token, :string, virtual: true, redact: true
    field :auth_token_hash, :string, redact: true
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
    # Requests per minute (`PhoenixKitSync.RateLimit`); 0 is no limit. A
    # sync makes one request per page of each table it pulls, and a full
    # install has some 200 tables, so the default leaves a sync of all of
    # them inside one minute with room to spare.
    field :rate_limit_requests_per_minute, :integer, default: 600

    # Additional security
    field :download_password, :string, virtual: true, redact: true
    field :download_password_hash, :string, redact: true
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
    |> validate_length(:name, max: 255)
    |> validate_length(:site_url, max: 255)
    |> validate_base_url()
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:approval_mode, @valid_approval_modes)
    |> validate_inclusion(:default_conflict_strategy, @valid_conflict_strategies)
    |> validate_number(:max_records_per_request,
      greater_than: 0,
      less_than_or_equal_to: @max_records_per_request_limit
    )
    |> validate_number(:rate_limit_requests_per_minute, greater_than_or_equal_to: 0)
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
      approved_by_uuid: resolve_user_uuid(admin_user_uuid),
      metadata: local_status_metadata(connection)
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
      suspended_reason: reason,
      metadata: local_status_metadata(connection)
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
      revoked_reason: reason,
      metadata: local_status_metadata(connection)
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
      suspended_reason: nil,
      metadata: local_status_metadata(connection)
    })
  end

  @remote_suspension_key "suspended_by_remote"

  @doc """
  Changeset for a status the remote site reports through the API.

  The peer is not trusted with this site's decisions, so only these moves
  exist, and only on a `"receiver"` row (the sender is the side that
  notifies):

  - `active` to `suspended` or `revoked`
  - `suspended` to `active` or `revoked`, when the suspension itself came
    from the peer (a suspension set here stays until an admin here lifts it)

  A `pending`, `revoked` or `expired` row never changes, and neither does a
  `"sender"` row: those statuses decide what the peer may read.

  Returns `{:ok, changeset}`, `:unchanged` when the row already has that
  status, or `{:error, :status_change_not_allowed}`.
  """
  @spec remote_status_changeset(t(), String.t()) ::
          {:ok, Ecto.Changeset.t()} | :unchanged | {:error, :status_change_not_allowed}
  def remote_status_changeset(%__MODULE__{direction: "receiver"} = connection, status)
      when is_binary(status) do
    remote_suspended? = remote_suspended?(connection)

    case {connection.status, status} do
      {same, same} ->
        :unchanged

      {"active", "suspended"} ->
        {:ok,
         change(connection, %{
           status: "suspended",
           suspended_at: UtilsDate.utc_now(),
           suspended_by_uuid: nil,
           suspended_reason: nil,
           metadata: Map.put(connection.metadata || %{}, @remote_suspension_key, true)
         })}

      {"suspended", "active"} when remote_suspended? ->
        {:ok, reactivate_changeset(connection)}

      {from, "revoked"} when from == "active" or (from == "suspended" and remote_suspended?) ->
        {:ok,
         change(connection, %{
           status: "revoked",
           revoked_at: UtilsDate.utc_now(),
           revoked_by_uuid: nil,
           revoked_reason: nil,
           metadata: local_status_metadata(connection)
         })}

      _other ->
        {:error, :status_change_not_allowed}
    end
  end

  def remote_status_changeset(%__MODULE__{}, _status), do: {:error, :status_change_not_allowed}

  @doc """
  Whether the connection's suspension was reported by the remote site
  rather than set by an admin here.
  """
  @spec remote_suspended?(t()) :: boolean()
  def remote_suspended?(%__MODULE__{
        status: "suspended",
        metadata: %{@remote_suspension_key => true}
      }),
      do: true

  def remote_suspended?(%__MODULE__{}), do: false

  # A status set on this site is this site's own: the marker that lets the
  # peer lift a suspension it reported goes with it.
  defp local_status_metadata(%__MODULE__{metadata: metadata}),
    do: Map.delete(metadata || %{}, @remote_suspension_key)

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
    |> validate_number(:max_records_per_request,
      greater_than: 0,
      less_than_or_equal_to: @max_records_per_request_limit
    )
    |> validate_number(:rate_limit_requests_per_minute, greater_than_or_equal_to: 0)
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
  @spec verify_auth_token(term(), term()) :: boolean()
  def verify_auth_token(%__MODULE__{auth_token_hash: hash}, token)
      when is_binary(token) and is_binary(hash) do
    Plug.Crypto.secure_compare(hash_token(token), hash)
  end

  def verify_auth_token(_, _), do: false

  @doc """
  Verifies a download password against the stored hash.
  """
  @spec verify_download_password(term(), term()) :: boolean()
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
  @spec active?(term()) :: boolean()
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
  @spec ip_allowed?(term(), term()) :: boolean()
  def ip_allowed?(%__MODULE__{ip_whitelist: []}, _ip), do: true
  def ip_allowed?(%__MODULE__{ip_whitelist: nil}, _ip), do: true

  def ip_allowed?(%__MODULE__{ip_whitelist: whitelist}, ip) when is_binary(ip) do
    ip in whitelist
  end

  def ip_allowed?(_, _), do: false

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
    host = normalize_host(uri.host)

    cond do
      uri.scheme not in ["http", "https"] ->
        add_error(changeset, :site_url, "must use http or https scheme")

      host == "" ->
        add_error(changeset, :site_url, "must include a hostname")

      Application.get_env(:phoenix_kit_sync, :allow_internal_urls, false) ->
        changeset

      true ->
        validate_public_host(changeset, host)
    end
  end

  defp validate_public_host(changeset, host) do
    cond do
      host == "local" or String.ends_with?(host, ".local") ->
        add_error(
          changeset,
          :site_url,
          "cannot point at .local mDNS hostnames (set allow_internal_urls if you need this)"
        )

      host == "localhost" or String.ends_with?(host, ".localhost") ->
        add_error(
          changeset,
          :site_url,
          "cannot point at localhost (set allow_internal_urls if you need this)"
        )

      internal_host?(host) ->
        add_error(
          changeset,
          :site_url,
          "cannot point at private/loopback/link-local addresses (set allow_internal_urls if you need this)"
        )

      true ->
        changeset
    end
  end

  # A hostname compares without case, and a fully-qualified name may end in
  # one dot: "LOCALHOST" and "localhost." are both localhost to a resolver.
  defp normalize_host(nil), do: ""

  defp normalize_host(host) when is_binary(host) do
    host = String.downcase(host)

    if String.ends_with?(host, "."), do: String.slice(host, 0..-2//1), else: host
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

  # IPv4-mapped (`::ffff:a.b.c.d`): the address a dual-stack socket connects
  # to is the IPv4 one.
  defp internal_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: internal_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp internal_ip?(_), do: false
end
