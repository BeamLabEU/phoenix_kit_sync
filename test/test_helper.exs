# Test helper for PhoenixKitSync test suite
#
# Unit tests (schemas, changesets, pure functions) run without a database.
# Integration tests require a running PostgreSQL — they are automatically
# excluded when the DB is unavailable.

alias PhoenixKitSync.Test.Repo, as: TestRepo

# Check if the test database exists before trying to connect
db_config = Application.get_env(:phoenix_kit_sync, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_sync_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. The sync tables come from
      # core (V37 creates them as `phoenix_kit_db_sync_*`; V44 renames to
      # `phoenix_kit_sync_*`; V56/V58/V61/V73/V74 evolve them). The
      # `phoenix_kit_settings` (V03), `phoenix_kit_activities` (V90), and
      # `uuid-ossp` / `pgcrypto` extensions + `uuid_generate_v7()` function
      # (V40) are also owned by core. No module-side DDL in this helper.
      #
      # `ensure_current/2` (core 1.7.105+ / phoenix_kit#515) re-applies
      # any newly-shipped Vxxx migrations on every boot by passing a
      # fresh wall-clock version to Ecto.Migrator. Replaces the old shape
      # that mixed inline DDL with `Ecto.Migrator.up(TestRepo, 0,
      # PhoenixKitSync.Migration, ...)` — the inline DDL drifted from
      # production schemas, and `up(_, 0, ...)` silently went stale once
      # `0` landed in `schema_migrations`. See
      # `dev_docs/migration_cleanup.md` for the staleness story.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run: createdb #{db_name}
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run: createdb #{db_name}
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_sync, :test_repo_available, repo_available)

# Start minimal services needed for tests
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Anything that creates a user goes through `PhoenixKit.Users.Auth.register_user/2`,
# which calls the Hammer-backed rate limiter. Without this its ETS table is
# absent and the call dies in `:ets.update_counter/4`. Connections carry real
# FKs to `phoenix_kit_users`, so tests that approve/suspend a connection need
# a genuine user (see `PhoenixKitSync.TestActor`).
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Start PhoenixKit.TaskSupervisor so PhoenixKitSync.AsyncTasks can route
# fire-and-forget tasks through the named supervisor as it does in
# production. Without this, the helper's `:exit` fallback fires and tests
# can't distinguish supervised from bare `Task.start`.
case Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start SessionStore so PhoenixKitSync.create_session/2 +
# PhoenixKitSync.validate_code/1 work in tests. The store is a
# GenServer that owns an ETS table; without it any code-based session
# operation crashes with "the table identifier does not refer to an
# existing ETS table".
case PhoenixKitSync.SessionStore.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start the test endpoint so Phoenix.LiveViewTest.live/2 can drive
# LiveViews through `/en/admin/sync/*` URLs. Only when the DB is
# available (otherwise integration tests are excluded anyway).
if repo_available do
  # PubSub server for the test endpoint — required by Phoenix.Socket
  # initialisation in Phoenix.ChannelTest.
  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKitSync.Test.PubSub)

  # Finch instance ConnectionNotifier reaches for via get_finch_name/0.
  # Required by tests that drive HTTP cross-site flows.
  {:ok, _} = Finch.start_link(name: PhoenixKit.Finch)

  {:ok, _pid} = PhoenixKitSync.Test.Endpoint.start_link()

  # Read the actual port the test endpoint bound to so test code can
  # build localhost URLs that ConnectionNotifier / WebSocketClient
  # actually reach. Phoenix.Endpoint.server_info/2 reports the bound
  # address tuple after Bandit has registered its listener.
  {:ok, {_addr, test_port}} = PhoenixKitSync.Test.Endpoint.server_info(:http)
  Application.put_env(:phoenix_kit_sync, :test_endpoint_port, test_port)

  # Pin URL prefix to "" via :persistent_term so PhoenixKit.Utils.Routes
  # doesn't try to query the settings table for the live URL prefix
  # during test mounts (which would be a cross-process sandbox query).
  :persistent_term.put({PhoenixKit.Config, :url_prefix}, "")
end

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

ExUnit.start(exclude: exclude)
