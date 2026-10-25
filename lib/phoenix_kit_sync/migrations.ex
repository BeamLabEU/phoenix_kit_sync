defmodule PhoenixKitSync.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_sync` — the protocol
  core's `mix phoenix_kit.update` discovers through `migration_module/0`:
  `current_version/0`, `migrated_version_runtime/1`, an idempotent `up/1` and a
  version-aware `down/1`. Same shape as `phoenix_kit_locations`' chain.

  ## What V1 is

  An ADOPTION step for the two tables core's chain creates for this module:
  `phoenix_kit_sync_connections` and `phoenix_kit_sync_transfers`. Their shape is core's V135 baseline plus V218, which sets the default of `phoenix_kit_sync_connections.rate_limit_requests_per_minute` to 600. The statements below re-state what a fresh core install builds today, with core's exact object names. V218 is why the package requires core 2.63.0 or later.

  `PhoenixKitSync.Migration` (singular) predates this chain: a fallback a host may still call from its own migration file. It is not the chain, and `mix phoenix_kit.update` never runs it.

    * On every existing install the tables are already there: each `CREATE
      TABLE IF NOT EXISTS`, guarded `DO $$ … pg_constraint … $$` block and
      `CREATE INDEX IF NOT EXISTS` finds its target and does nothing. The only
      new object is the `pksyn_schema:1` marker.
    * On an install whose core no longer creates the tables, the same
      statements create them, identical to what core built.
      `test/integration/migrations_build_alone_test.exs` proves that against
      core's chain (core's `PhoenixKit.TestSupport.ModuleChainCheck`).

  From V1 on, this chain owns the tables' shape: a change to them is a new
  version here, never a core migration (core enforces that since V223; see
  core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's
  `ExpectedSchema` manifest hands these tables over, a version that reshapes an
  object the manifest declares must first take it out of the manifest, or
  `mix phoenix_kit.repair` restores the old shape; a version that only adds
  objects the manifest never names needs no core step.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it never drops a table. The rows are
  the site's sync connections and their transfer history, and on every current
  install core created the tables.
  `test/phoenix_kit_sync/migrations_test.exs` pins this by asserting that no
  statement this module can emit matches `DROP`, `TRUNCATE` or `DELETE`.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.

  The migrated version is a `pksyn_schema:<N>` `COMMENT ON TABLE` marker on
  `phoenix_kit_sync_connections`; a table without one reads as version 0 — the shape
  core built before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pksyn_schema:"
  @version_table "phoenix_kit_sync_connections"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pksyn_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pksyn_schema:<N>` marker when present; a marker-less table
  reads as `0` (core's shape — V1 is purely adoptive, there is no pre-chain
  content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already created
  the tables and on one with none of them.

  V1 order: every `CREATE TABLE`, then every constraint guard (primary keys,
  then foreign keys), then every index, then the version marker last.

  `target` selects how much of the chain to emit (default `current_version/0`);
  the wrapper migration core's update task generates passes an explicit
  `:version`, and a stale wrapper asking for an older version must not receive
  a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(prefix, p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of the tables core's chain creates ─────────────────────

  defp v1_statements(prefix, p) do
    [tables(p), constraints(prefix, p), indexes(prefix, p)]
  end

  # Columns, types, defaults and order as a fresh core install builds them.
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_sync_connections (
        "name" character varying(255) NOT NULL,
        "direction" character varying(10) NOT NULL,
        "site_url" character varying(255) NOT NULL,
        "auth_token" character varying(255),
        "auth_token_hash" character varying(255),
        "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
        "approval_mode" character varying(20) DEFAULT 'require_approval'::character varying,
        "allowed_tables" character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        "excluded_tables" character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        "auto_approve_tables" character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        "expires_at" timestamp with time zone,
        "max_downloads" integer,
        "downloads_used" integer DEFAULT 0 NOT NULL,
        "max_records_total" bigint,
        "records_downloaded" bigint DEFAULT 0 NOT NULL,
        "max_records_per_request" integer DEFAULT 10000 NOT NULL,
        "rate_limit_requests_per_minute" integer DEFAULT 600 NOT NULL,
        "download_password_hash" character varying(255),
        "ip_whitelist" character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        "allowed_hours_start" integer,
        "allowed_hours_end" integer,
        "default_conflict_strategy" character varying(20) DEFAULT 'skip'::character varying,
        "auto_sync_enabled" boolean DEFAULT false NOT NULL,
        "auto_sync_tables" character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
        "auto_sync_interval_minutes" integer DEFAULT 60 NOT NULL,
        "approved_at" timestamp with time zone,
        "suspended_at" timestamp with time zone,
        "suspended_reason" character varying(255),
        "revoked_at" timestamp with time zone,
        "revoked_reason" character varying(255),
        "last_connected_at" timestamp with time zone,
        "last_transfer_at" timestamp with time zone,
        "total_transfers" integer DEFAULT 0 NOT NULL,
        "total_records_transferred" bigint DEFAULT 0 NOT NULL,
        "total_bytes_transferred" bigint DEFAULT 0 NOT NULL,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "approved_by_uuid" uuid,
        "suspended_by_uuid" uuid,
        "revoked_by_uuid" uuid,
        "created_by_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_sync_transfers (
        "direction" character varying(10) NOT NULL,
        "session_code" character varying(20),
        "remote_site_url" character varying(255),
        "table_name" character varying(255) NOT NULL,
        "records_requested" integer DEFAULT 0 NOT NULL,
        "records_transferred" integer DEFAULT 0 NOT NULL,
        "records_created" integer DEFAULT 0 NOT NULL,
        "records_updated" integer DEFAULT 0 NOT NULL,
        "records_skipped" integer DEFAULT 0 NOT NULL,
        "records_failed" integer DEFAULT 0 NOT NULL,
        "bytes_transferred" bigint DEFAULT 0 NOT NULL,
        "conflict_strategy" character varying(20),
        "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
        "requires_approval" boolean DEFAULT false NOT NULL,
        "approved_at" timestamp with time zone,
        "denied_at" timestamp with time zone,
        "denial_reason" character varying(255),
        "approval_expires_at" timestamp with time zone,
        "requester_ip" character varying(255),
        "requester_user_agent" character varying(255),
        "error_message" text,
        "started_at" timestamp with time zone,
        "completed_at" timestamp with time zone,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "approved_by_uuid" uuid,
        "denied_by_uuid" uuid,
        "initiated_by_uuid" uuid,
        "connection_uuid" uuid
      )
      """
    ]
  end

  # Core's constraint names.
  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_connections",
        "phoenix_kit_sync_connections_pkey",
        "ALTER TABLE #{p}phoenix_kit_sync_connections ADD CONSTRAINT phoenix_kit_sync_connections_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_transfers",
        "phoenix_kit_sync_transfers_pkey",
        "ALTER TABLE #{p}phoenix_kit_sync_transfers ADD CONSTRAINT phoenix_kit_sync_transfers_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_connections",
        "fk_sync_connections_approved_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_connections ADD CONSTRAINT fk_sync_connections_approved_by_uuid FOREIGN KEY (approved_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_connections",
        "fk_sync_connections_created_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_connections ADD CONSTRAINT fk_sync_connections_created_by_uuid FOREIGN KEY (created_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_connections",
        "fk_sync_connections_revoked_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_connections ADD CONSTRAINT fk_sync_connections_revoked_by_uuid FOREIGN KEY (revoked_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_connections",
        "fk_sync_connections_suspended_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_connections ADD CONSTRAINT fk_sync_connections_suspended_by_uuid FOREIGN KEY (suspended_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_transfers",
        "fk_sync_transfers_approved_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_transfers ADD CONSTRAINT fk_sync_transfers_approved_by_uuid FOREIGN KEY (approved_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_transfers",
        "fk_sync_transfers_connection_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_transfers ADD CONSTRAINT fk_sync_transfers_connection_uuid FOREIGN KEY (connection_uuid) REFERENCES #{p}phoenix_kit_sync_connections(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_transfers",
        "fk_sync_transfers_denied_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_transfers ADD CONSTRAINT fk_sync_transfers_denied_by_uuid FOREIGN KEY (denied_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_sync_transfers",
        "fk_sync_transfers_initiated_by_uuid",
        "ALTER TABLE #{p}phoenix_kit_sync_transfers ADD CONSTRAINT fk_sync_transfers_initiated_by_uuid FOREIGN KEY (initiated_by_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL"
      )
    ]
  end

  # Index names are core's. They stay bare on CREATE (an index lives in its
  # table's schema).
  defp indexes(prefix, p) do
    np = name_prefix(prefix)

    [
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_db_sync_connections_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_approved_by_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (approved_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_created_by_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (created_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_direction_idx ON #{p}phoenix_kit_sync_connections USING btree (direction)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_expires_at_idx ON #{p}phoenix_kit_sync_connections USING btree (expires_at)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_revoked_by_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (revoked_by_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_sync_connections_site_direction_uidx ON #{p}phoenix_kit_sync_connections USING btree (site_url, direction)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_status_idx ON #{p}phoenix_kit_sync_connections USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_connections_suspended_by_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (suspended_by_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{np}phoenix_kit_sync_connections_uuid_idx ON #{p}phoenix_kit_sync_connections USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_db_sync_transfers_uuid_idx ON #{p}phoenix_kit_sync_transfers USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_approval_idx ON #{p}phoenix_kit_sync_transfers USING btree (requires_approval, status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_approved_by_uuid_idx ON #{p}phoenix_kit_sync_transfers USING btree (approved_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_connection_uuid_idx ON #{p}phoenix_kit_sync_transfers USING btree (connection_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_denied_by_uuid_idx ON #{p}phoenix_kit_sync_transfers USING btree (denied_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_direction_idx ON #{p}phoenix_kit_sync_transfers USING btree (direction)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_initiated_by_uuid_idx ON #{p}phoenix_kit_sync_transfers USING btree (initiated_by_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_inserted_at_idx ON #{p}phoenix_kit_sync_transfers USING btree (inserted_at)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_sync_transfers_status_idx ON #{p}phoenix_kit_sync_transfers USING btree (status)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  # Core's V56 convention puts the schema name in front of a few index names
  # on a named-schema install, and none on `public`; the chain names them the
  # same way, so it adopts core's index instead of building a second one.
  defp name_prefix("public"), do: ""
  defp name_prefix(prefix), do: "#{prefix}_"

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
