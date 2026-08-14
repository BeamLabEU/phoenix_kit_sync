defmodule PhoenixKitSync.Batch2RevalidationTest do
  @moduledoc """
  Pins the deltas introduced by the 2026-04-26 re-validation pass
  (Batch 2). Every change in this batch should have at least one
  assertion here that would fail on revert. Grouped by area, not
  by file, so the file is small but each missing pin would surface
  immediately on running the suite.

  Covered:
  - `handle_info/2` catch-all on every admin LV — sending an
    unrouted message must not crash the process (5 LVs)
  - structural pin on the `Logger.debug` clause body so a future
    refactor can't silently drop the log line
  - `phx-disable-with` on every async / destructive `phx-click`
    button (7 sites)
  - 12 hardcoded heex strings → `gettext/1` wraps (default English
    output preserved)
  - `pgcrypto` extension available in test DB (used by
    `uuid_generate_v7`)
  - `IO.puts` removed from `@doc` examples (3 sites)
  - `enabled?/0` declares both `rescue` and `catch :exit` clauses
  """

  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.Repo, as: TestRepo
  alias PhoenixKitSync.Transfers

  # ---------------------------------------------------------------
  # handle_info/2 catch-all
  # ---------------------------------------------------------------
  #
  # The catch-all clause prevents `FunctionClauseError` when a stray
  # PubSub broadcast or monitor signal arrives. Asserting that
  # `render/1` still returns a binary after `send/2` proves the
  # clause is present and dispatches correctly. The Logger.debug
  # body is pinned structurally below.

  describe "handle_info catch-all keeps the LV alive" do
    test "ConnectionsLive does not crash on stray message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/connections")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end

    test "Sender LV does not crash on stray message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/send")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:weird, :tuple})

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end

    test "Receiver LV does not crash on stray message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/receive")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:weird, :tuple})

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end

    test "History LV does not crash on stray message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:weird, :tuple})

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end

    test "Index LV does not crash on stray message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:weird, :tuple})

      assert is_binary(render(view))
      assert Process.alive?(view.pid)
    end

    test "every admin LV's catch-all clause emits a Logger.debug line" do
      # Structural pin so a future refactor can't drop the log without
      # tripping the test. Test config sets `:logger, level: :warning`,
      # so capture_log can't reliably observe :debug emission — the
      # source check is the cheapest pin that won't false-pass under
      # that level filter.
      for path <- [
            "lib/phoenix_kit_sync/web/connections_live.ex",
            "lib/phoenix_kit_sync/web/sender.ex",
            "lib/phoenix_kit_sync/web/receiver.ex",
            "lib/phoenix_kit_sync/web/history.ex",
            "lib/phoenix_kit_sync/web/index.ex"
          ] do
        source = File.read!(path)

        assert source =~ ~r/def handle_info\(msg, socket\) do[\s\S]+?Logger\.debug/,
               "#{path} catch-all must call Logger.debug on the message"
      end
    end
  end

  # ---------------------------------------------------------------
  # phx-disable-with on async / destructive phx-click buttons
  # ---------------------------------------------------------------
  #
  # Each new attribute is pinned by the actual rendered HTML when the
  # relevant button is in scope, OR by source grep when the button
  # only renders in deep flows that aren't worth re-creating from a
  # cold mount.

  describe "phx-disable-with on async / destructive phx-click buttons" do
    test "approve_connection button has phx-disable-with (rendered in list)", %{conn: conn} do
      _pending = create_pending_sender_connection()

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections")

      assert html =~ ~r/phx-click="approve_connection"[^>]*phx-disable-with/s,
             "approve_connection button must declare phx-disable-with"
    end

    test "reactivate_connection button has phx-disable-with (rendered in list)", %{conn: conn} do
      _suspended = create_suspended_sender_connection()

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections")

      assert html =~ ~r/phx-click="reactivate_connection"[^>]*phx-disable-with/s,
             "reactivate_connection button must declare phx-disable-with"
    end

    test "approve_transfer button has phx-disable-with (modal open)", %{conn: conn} do
      connection = create_active_sender_connection()

      {:ok, transfer} =
        Transfers.create_transfer(%{
          "direction" => "send",
          "table_name" => "approve_pin",
          "connection_uuid" => connection.uuid,
          "status" => "pending_approval"
        })

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history")

      html = render_click(view, "show_approval_modal", %{"uuid" => transfer.uuid})

      assert html =~ ~r/phx-click="approve_transfer"[^>]*phx-disable-with/s,
             "approve_transfer button must declare phx-disable-with"
    end

    test "transfer_detail_table, start_transfer, generate_code, regenerate_code source pins" do
      # These render only in deep receiver / sender flows that need
      # session state from another peer to mount cleanly. Source-grep
      # is the cheapest pin that catches a regression on revert.
      receiver_source = File.read!("lib/phoenix_kit_sync/web/receiver.ex")
      sender_source = File.read!("lib/phoenix_kit_sync/web/sender.ex")

      assert receiver_source =~ ~r/phx-click="transfer_detail_table"\s+phx-disable-with/,
             "transfer_detail_table button must declare phx-disable-with"

      assert receiver_source =~ ~r/phx-click="start_transfer"\s+phx-disable-with/,
             "start_transfer button must declare phx-disable-with"

      assert sender_source =~ ~r/phx-click="generate_code"\s+phx-disable-with/,
             "generate_code button must declare phx-disable-with"

      assert sender_source =~ ~r/phx-click="regenerate_code"\s+phx-disable-with/,
             "regenerate_code button must declare phx-disable-with"
    end
  end

  # ---------------------------------------------------------------
  # gettext wraps preserve default-locale text
  # ---------------------------------------------------------------

  describe "12 hardcoded heex strings now flow through gettext" do
    test "history.ex deny-form placeholder renders the gettext string", %{conn: conn} do
      connection = create_active_sender_connection()

      {:ok, transfer} =
        Transfers.create_transfer(%{
          "direction" => "send",
          "table_name" => "deny_pin",
          "connection_uuid" => connection.uuid,
          "status" => "pending_approval"
        })

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history")

      html = render_click(view, "show_approval_modal", %{"uuid" => transfer.uuid})

      assert html =~ ~s|placeholder="Reason (optional)"|,
             "deny-form reason placeholder must render the gettext-wrapped string"
    end

    test "connections_live source no longer contains raw English heex strings" do
      source = File.read!("lib/phoenix_kit_sync/web/connections_live.ex")

      # Each pattern would match ONLY if the gettext wrap regressed.
      refute source =~ ~r/badge-success">Enabled</,
             "Enabled badge must be wrapped in gettext"

      refute source =~ ~r/badge-ghost">Disabled</,
             "Disabled badge must be wrapped in gettext"

      refute source =~ ~r/text-base-content\/70">Record counts:</,
             "Record counts: label must be wrapped in gettext"

      refute source =~ ~r/text-primary">Sender</,
             "Sender legend must be wrapped in gettext"

      refute source =~ ~r/text-success">Local</,
             "Local legend must be wrapped in gettext"

      refute source =~ ~r/= differs/,
             "= differs legend must be wrapped in gettext"

      refute source =~ ~r/data-tip="Used by selected tables/,
             "data-tip must be wrapped in gettext"

      refute source =~ ~r/<span>Loading table schema/,
             "Loading table schema… must be wrapped in gettext"

      refute source =~ ~r/loading-xs"><\/span> Creating\.\.\./,
             "Creating… loading state must be wrapped in gettext"

      refute source =~ ~r/placeholder="From"/,
             "placeholder=\"From\" must be wrapped in gettext"

      refute source =~ ~r/placeholder="To"/,
             "placeholder=\"To\" must be wrapped in gettext"
    end

    test "history.ex source no longer contains the raw Reason placeholder" do
      source = File.read!("lib/phoenix_kit_sync/web/history.ex")

      refute source =~ ~r/placeholder="Reason \(optional\)"/,
             "Reason (optional) placeholder must be wrapped in gettext"
    end
  end

  # ---------------------------------------------------------------
  # IO.puts removed from @doc examples
  # ---------------------------------------------------------------

  describe "IO.puts removed from @doc examples" do
    test "connections.ex no longer documents IO.puts in @doc examples" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      refute source =~ ~r/IO\.puts\("Auth token:/,
             "create_connection @doc example must not show IO.puts"

      refute source =~ ~r/IO\.puts\("Expired #\{count\} connections/,
             "expire_connections @doc example must not show IO.puts"
    end

    test "transfers.ex no longer documents IO.puts in @doc examples" do
      source = File.read!("lib/phoenix_kit_sync/transfers.ex")

      refute source =~ ~r/IO\.puts\("Expired #\{count\} approval requests/,
             "expire_pending_approvals @doc example must not show IO.puts"
    end
  end

  # ---------------------------------------------------------------
  # pgcrypto extension available
  # ---------------------------------------------------------------

  describe "pgcrypto extension is enabled in test DB" do
    test "gen_random_bytes function is callable" do
      # uuid_generate_v7() depends on this; the extension was missing
      # from test_helper.exs pre-Batch 2. A fresh `createdb` would have
      # broken every UUID-defaulted insert without it.
      result = TestRepo.query!("SELECT length(gen_random_bytes(10))")
      assert result.rows == [[10]]
    end
  end

  # ---------------------------------------------------------------
  # enabled?/0 — rescue + catch :exit shape
  # ---------------------------------------------------------------

  describe "enabled?/0 defensive shape" do
    test "source declares both rescue and catch :exit clauses" do
      # The catch :exit branch only fires under sandbox-shutdown
      # conditions that are hard to reproduce in a normal test
      # process. Assert structurally so a future refactor can't
      # silently drop it (the workspace AGENTS.md flaky-test trap
      # explains why this matters: without it, a 1-in-10 unit test
      # flakes when the prior test's sandbox owner has just exited).
      source = File.read!("lib/phoenix_kit_sync.ex")

      assert source =~ ~r/def enabled\?[\s\S]+?rescue[\s\S]+?catch[\s\S]+?:exit, _ -> false/,
             "enabled?/0 must have BOTH `rescue _ -> false` AND `catch :exit, _ -> false` clauses"
    end
  end

  # ---------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------

  defp create_pending_sender_connection do
    {:ok, pending, _token} =
      Connections.create_connection(%{
        "name" => "Pending #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://pending-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "require_approval"
      })

    pending
  end

  defp create_active_sender_connection do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "Active #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://active-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    active
  end

  defp create_suspended_sender_connection do
    active = create_active_sender_connection()

    {:ok, suspended} =
      Connections.suspend_connection(active, PhoenixKitSync.TestActor.uuid(), "test")

    suspended
  end
end
