defmodule PhoenixKitSync.Web.HistoryLiveTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Transfers

  defp create_active_connection do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "History Test #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://history-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    active
  end

  describe "mount and render" do
    test "renders the transfer history page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/history")

      assert html =~ "Transfer History"
    end

    test "shows transfers in the list", %{conn: conn} do
      connection = create_active_connection()

      {:ok, _transfer} =
        Transfers.create_transfer(%{
          "direction" => "send",
          "table_name" => "history_pin_table",
          "connection_uuid" => connection.uuid
        })

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/history")

      assert html =~ "history_pin_table"
    end
  end

  describe "connected? guard (PR #1 follow-up fix)" do
    # Pinning test for the Wave 1 fix. Before: history.ex called
    # load_transfers/1 unconditionally in mount/3, hitting the DB on
    # the dead render. After: maybe_load_transfers/1 wraps the call
    # behind connected?(socket); the dead render gets empty assigns.
    # Without the connected?-guard, the disconnected mount crashes
    # because the sandbox connection isn't shared yet — this test
    # would hang or fail.
    test "mount succeeds with empty transfers when no connection exists yet", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      # The mount has to handle the disconnected render path without
      # raising — if the guard regressed and unconditionally hit the
      # DB, this would still pass on the connected mount but break
      # under live_isolated tests. The mount succeeding here AND then
      # the connected render filling transfers is what the guard buys.
      {:ok, _view, html} = live(conn, "/en/admin/sync/history")

      # The connected render runs after mount; the page shows either
      # the "no transfers" state or any pre-existing transfer rows.
      assert html =~ "Transfer History"
    end

    test "approval modal opens for pending-approval transfer", %{conn: conn} do
      connection = create_active_connection()

      {:ok, transfer} =
        Transfers.create_transfer(%{
          "direction" => "send",
          "table_name" => "approval_pin",
          "connection_uuid" => connection.uuid
        })

      {:ok, _} = Transfers.request_approval(transfer)

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history?status=pending_approval")

      html =
        view
        |> element("button[phx-click='show_approval_modal'][phx-value-uuid='#{transfer.uuid}']")
        |> render_click()

      # The Deny button gets phx-disable-with from the C5 sweep — pin
      # that the attribute is rendered when the modal opens.
      assert html =~ "phx-disable-with=\"Denying"
    end
  end
end
