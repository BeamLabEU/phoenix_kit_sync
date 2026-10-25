defmodule PhoenixKitSync.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKitSync.Migrations

  @tables ~w(
    phoenix_kit_sync_connections
    phoenix_kit_sync_transfers
  )

  # Every index the chain owns, constraint-backed ones excluded. The "guarded"
  # test below only scans statements that exist, so without this list all of
  # them could be deleted and it would still pass.
  @indexes ~w(
    phoenix_kit_db_sync_connections_uuid_idx
    phoenix_kit_sync_connections_approved_by_uuid_idx
    phoenix_kit_sync_connections_created_by_uuid_idx
    phoenix_kit_sync_connections_direction_idx
    phoenix_kit_sync_connections_expires_at_idx
    phoenix_kit_sync_connections_revoked_by_uuid_idx
    phoenix_kit_sync_connections_site_direction_uidx
    phoenix_kit_sync_connections_status_idx
    phoenix_kit_sync_connections_suspended_by_uuid_idx
    phoenix_kit_sync_connections_uuid_idx
    phoenix_kit_db_sync_transfers_uuid_idx
    phoenix_kit_sync_transfers_approval_idx
    phoenix_kit_sync_transfers_approved_by_uuid_idx
    phoenix_kit_sync_transfers_connection_uuid_idx
    phoenix_kit_sync_transfers_denied_by_uuid_idx
    phoenix_kit_sync_transfers_direction_idx
    phoenix_kit_sync_transfers_initiated_by_uuid_idx
    phoenix_kit_sync_transfers_inserted_at_idx
    phoenix_kit_sync_transfers_status_idx
  )

  # 2 primary keys, 8 foreign keys.
  @constraints ~w(
    phoenix_kit_sync_connections_pkey
    phoenix_kit_sync_transfers_pkey
    fk_sync_connections_approved_by_uuid
    fk_sync_connections_created_by_uuid
    fk_sync_connections_revoked_by_uuid
    fk_sync_connections_suspended_by_uuid
    fk_sync_transfers_approved_by_uuid
    fk_sync_transfers_connection_uuid
    fk_sync_transfers_denied_by_uuid
    fk_sync_transfers_initiated_by_uuid
  )

  test "chain is V1 and marks phoenix_kit_sync_connections" do
    assert Migrations.current_version() == 1
    assert Migrations.version_table() == "phoenix_kit_sync_connections"
  end

  test "the module registers the chain" do
    assert PhoenixKitSync.migration_module() == Migrations
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} (")),
             "missing CREATE TABLE for #{t}"
    end

    assert Enum.count(stmts, &(&1 =~ ~r/CREATE TABLE/)) == length(@tables)

    assert List.last(stmts) ==
             "COMMENT ON TABLE public.phoenix_kit_sync_connections IS 'pksyn_schema:1'"
  end

  test "up_statements/2 defaults target to current_version/0 and clamps above it" do
    assert Migrations.up_statements("public") == Migrations.up_statements("public", 1)
    assert Migrations.up_statements("public", 99) == Migrations.up_statements("public", 1)
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # FK referential actions are copied verbatim from core, not destructive
      # statements.
      scanned =
        Regex.replace(~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i, s, "")

      refute scanned =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "every pinned index name appears inside a CREATE ... IF NOT EXISTS statement" do
    stmts = Migrations.up_statements("public")

    for name <- @indexes do
      assert Enum.any?(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS #{name}\b/)),
             "missing guarded index #{name}"
    end

    assert length(@indexes) ==
             Enum.count(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/))
  end

  test "every pinned constraint name appears inside a guarded DO $$ block" do
    stmts = Migrations.up_statements("public")

    for name <- @constraints do
      assert Enum.any?(stmts, fn s -> s =~ ~r/DO \$\$/ and s =~ ~r/ADD CONSTRAINT #{name}\b/ end),
             "missing guarded constraint #{name}"
    end

    assert length(@constraints) == Enum.count(stmts, &(&1 =~ ~r/DO \$\$/))
  end

  test "the guard checks the same table and schema the constraint is added to" do
    for s <- Migrations.up_statements("tenant_a"), s =~ ~r/DO \$\$/ do
      [_, name] = Regex.run(~r/c\.conname = '([^']+)'/, s)
      [_, table] = Regex.run(~r/t\.relname = '([^']+)'/, s)

      assert s =~ "n.nspname = 'tenant_a'"
      assert s =~ "ALTER TABLE tenant_a.#{table} ADD CONSTRAINT #{name} "
    end
  end

  test "each foreign key keeps core's delete action" do
    stmts = Migrations.up_statements("public")

    for {name, action} <- [
          {"fk_sync_connections_approved_by_uuid", "SET NULL"},
          {"fk_sync_connections_created_by_uuid", "SET NULL"},
          {"fk_sync_connections_revoked_by_uuid", "SET NULL"},
          {"fk_sync_connections_suspended_by_uuid", "SET NULL"},
          {"fk_sync_transfers_approved_by_uuid", "SET NULL"},
          {"fk_sync_transfers_connection_uuid", "SET NULL"},
          {"fk_sync_transfers_denied_by_uuid", "SET NULL"},
          {"fk_sync_transfers_initiated_by_uuid", "SET NULL"}
        ] do
      [fk] = Enum.filter(stmts, &(&1 =~ "ADD CONSTRAINT #{name} FOREIGN KEY"))
      assert fk =~ "ON DELETE #{action}", "#{name} should be ON DELETE #{action}"
    end
  end

  test "a prefix is threaded through tables, FK targets and the uuid default" do
    joined = Enum.join(Migrations.up_statements("tenant_a"), "\n")

    refute joined =~ "public."
    assert joined =~ "DEFAULT tenant_a.uuid_generate_v7()"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_sync_connections(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_users(uuid)"
    assert joined =~ "COMMENT ON TABLE tenant_a.phoenix_kit_sync_connections IS 'pksyn_schema:1'"
  end

  # Core's V56 convention: on a named-schema install a few index names start
  # with the schema name (none on `public`). The chain must name them alike,
  # or it builds a second index beside core's instead of adopting it.
  test "index names follow core's schema-name convention" do
    assert Enum.any?(
             Migrations.up_statements("public"),
             &(&1 =~
                 "INDEX IF NOT EXISTS phoenix_kit_sync_connections_uuid_idx ON public.phoenix_kit_sync_connections ")
           )

    assert Enum.any?(
             Migrations.up_statements("tenant_a"),
             &(&1 =~
                 "INDEX IF NOT EXISTS tenant_a_phoenix_kit_sync_connections_uuid_idx ON tenant_a.phoenix_kit_sync_connections ")
           )
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_sync_connections IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_sync_connections IS 'pksyn_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
    assert_raise ArgumentError, fn -> Migrations.down_statements("x'y", 0) end
    assert_raise ArgumentError, fn -> Migrations.migrated_version_runtime(prefix: "a b") end
  end

  # ── the drift lock ───────────────────────────────────────────────────
  #
  # Core's `ExpectedSchema` manifest still audits these tables, and V1 only
  # holds together while this chain reproduces what that manifest requires.
  # Objects are picked by table name, not by the manifest's `owner:` label,
  # which predates `PhoenixKit.Migrations.ModuleOwnedTables`.
  describe "core's ExpectedSchema manifest" do
    setup do
      case Resolver.resolve() do
        {:ok, manifest} -> {:ok, objects: owned_objects(manifest)}
        {:error, :not_generated} -> {:ok, objects: nil}
      end
    end

    test "every required object of the sync tables is emitted by up_statements/1", ctx do
      if ctx.objects do
        refute ctx.objects == []

        stmts = Migrations.up_statements("public")

        missing =
          ctx.objects
          |> Enum.filter(&(&1.presence == :required))
          |> Enum.reject(&emitted?(stmts, &1))
          |> Enum.map(& &1.id)

        assert missing == [],
               "core's manifest requires these on a fresh install, and the chain " <>
                 "does not create them:\n  " <> Enum.join(missing, "\n  ")
      end
    end

    test "no object core deliberately dropped is re-created", ctx do
      if ctx.objects do
        stmts = Migrations.up_statements("public")

        resurrected =
          ctx.objects
          |> Enum.filter(&(&1.presence == :legacy_optional and emitted?(stmts, &1)))
          |> Enum.map(& &1.id)

        assert resurrected == [],
               "chain re-creates objects core deliberately dropped:\n  " <>
                 Enum.join(resurrected, "\n  ")
      end
    end
  end

  defp owned_objects(manifest) do
    Enum.filter(manifest.objects("public"), &(object_table(&1) in @tables))
  end

  defp object_table(%{id: "table:" <> table}), do: table
  defp object_table(%{id: "column:" <> rest}), do: rest |> String.split(".") |> hd()
  defp object_table(%{id: "constraint:" <> rest}), do: rest |> String.split(".") |> hd()
  defp object_table(%{class: :index, check: {:catalog, %{table: table}}}), do: table
  defp object_table(_object), do: nil

  # The manifest's id format (`table:<t>` / `column:<t>.<c>` / `index:<name>`
  # / `constraint:<t>.<name>`) identifies the object in the emitted DDL.
  defp emitted?(stmts, %{class: :table, id: "table:" <> table}) do
    Enum.any?(stmts, &creates_table?(&1, table))
  end

  defp emitted?(stmts, %{class: :index, id: "index:" <> name}) do
    Enum.any?(stmts, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON "))
  end

  defp emitted?(stmts, %{class: :column, id: "column:" <> rest}) do
    [table, column] = String.split(rest, ".", parts: 2)

    stmts
    |> Enum.find(&creates_table?(&1, table))
    |> declared_columns()
    |> Enum.member?(column)
  end

  defp emitted?(stmts, %{class: :constraint, id: "constraint:" <> rest}) do
    [table, name] = String.split(rest, ".", parts: 2)

    Enum.any?(stmts, fn s ->
      String.contains?(s, "ALTER TABLE public.#{table} ADD CONSTRAINT #{name} ")
    end)
  end

  defp creates_table?(statement, table) do
    String.contains?(statement, "CREATE TABLE IF NOT EXISTS public.#{table} (")
  end

  defp declared_columns(nil), do: []

  defp declared_columns(statement) do
    statement
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["CREATE ", "CONSTRAINT ", ")"])))
    |> Enum.map(fn line -> line |> String.split(" ", parts: 2) |> hd() |> String.trim("\"") end)
  end
end
