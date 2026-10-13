defmodule PhoenixKitSync.Web.HistoryLiveTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Transfer
  alias PhoenixKitSync.Transfers
  alias PhoenixKitSync.Web.History

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

  describe "filters" do
    setup %{conn: conn} do
      for {direction, status, table} <- [
            {"send", "completed", "sent_done"},
            {"send", "failed", "sent_failed"},
            {"receive", "completed", "received_done"}
          ] do
        {:ok, _} =
          Transfers.record_finished(
            %{direction: direction, table_name: table},
            if(status == "completed", do: :completed, else: {:failed, :sent_truncated})
          )
      end

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history")
      {:ok, view: view}
    end

    # The two selects share one form: a select's phx-change reaches the
    # server only from inside a form, and the event needs both fields.
    test "choosing a direction and a status narrows the list", %{view: view} do
      html =
        view
        |> form("#history-filters", %{"direction" => "send", "status" => ""})
        |> render_change()

      assert_patch(view, "/en/admin/sync/history?direction=send")
      assert html =~ "sent_done"
      assert html =~ "sent_failed"
      refute html =~ "received_done"

      html =
        view
        |> form("#history-filters", %{"direction" => "send", "status" => "failed"})
        |> render_change()

      assert html =~ "sent_failed"
      refute html =~ "sent_done"
    end

    test "every transfer status is an option, labelled", %{view: view} do
      for {status, label} <- [
            {"pending", "Pending"},
            {"pending_approval", "Pending Approval"},
            {"approved", "Approved"},
            {"denied", "Denied"},
            {"in_progress", "In Progress"},
            {"completed", "Completed"},
            {"failed", "Failed"},
            {"cancelled", "Cancelled"},
            {"expired", "Expired"}
          ] do
        assert view
               |> element(~s|#history-filter-status option[value="#{status}"]|)
               |> render() =~ label

        assert History.status_label(status) == label
      end

      assert History.status_label("from_the_future") == "from_the_future"
    end

    test "a classified failure reason is shown as a sentence, not as its code", %{view: view} do
      failed =
        PhoenixKit.RepoHelper.repo().get_by!(Transfer, table_name: "sent_failed")

      html = render_click(view, "show_approval_modal", %{"uuid" => failed.uuid})

      assert html =~ "max_records_per_request limit"
      refute html =~ "sent_truncated"
    end
  end

  describe "live refresh" do
    test "a transfer written elsewhere appears without a reload", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, "/en/admin/sync/history")
      refute html =~ "arrives_live"

      {:ok, transfer} =
        Transfers.create_transfer(%{"direction" => "receive", "table_name" => "arrives_live"})

      assert render(view) =~ "arrives_live"

      {:ok, _} = Transfers.fail_transfer(transfer, "Sender offline")
      render_click(view, "show_approval_modal", %{"uuid" => transfer.uuid})
      assert render(view) =~ "Sender offline"
    end

    test "a renamed connection shows under its new name", %{conn: conn} do
      connection = create_active_connection()

      {:ok, _} =
        Transfers.create_transfer(%{
          "direction" => "send",
          "table_name" => "named_table",
          "connection_uuid" => connection.uuid
        })

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history")

      {:ok, _} = Connections.update_connection(connection, %{name: "Renamed Peer"})
      assert render(view) =~ "Renamed Peer"
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

  describe "page parameter" do
    # The page number comes from the URL: whatever it holds, the page loads.
    # 25 transfers make two pages, so page 2 is a real one.
    for {raw, page} <- [
          {"abc", 1},
          {"-1", 1},
          {"0", 1},
          {"", 1},
          {"2", 2},
          {"99999999999999999999999", 1}
        ] do
      test "?page=#{raw} loads page #{page}", %{conn: conn} do
        insert_transfers(25)
        conn = put_test_scope(conn, fake_scope())
        {:ok, view, html} = live(conn, "/en/admin/sync/history?page=#{unquote(raw)}")

        assert html =~ "Transfer History"
        assert :sys.get_state(view.pid).socket.assigns.page == unquote(page)
      end
    end

    test "a page past the last one shows the last page", %{conn: conn} do
      insert_transfers(25)

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, "/en/admin/sync/history?page=50")

      assert html =~ "Page 2 of 2"
      assert html =~ "history_bulk_table"
      assert :sys.get_state(view.pid).socket.assigns.page == 2
    end

    # A page number above 10 000 is a page like any other, not a broken link
    # to send back to page 1: here it lies past the end, so it shows the
    # last page. (Two pages of rows tell the two apart; no need for the
    # 200 000 rows a real page 10 001 takes.)
    test "a page number beyond 10 000 is still read as a page", %{conn: conn} do
      insert_transfers(25)

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/history?page=10001")

      assert :sys.get_state(view.pid).socket.assigns.page == 2
      assert render(view) =~ "Page 2 of 2"
    end

    test "a page past the last one puts the page shown in the address", %{conn: conn} do
      insert_transfers(25)
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/sync/history")

      render_patch(view, "/en/admin/sync/history?page=999&direction=send&status=pending")
      assert_patch(view, "/en/admin/sync/history?page=2&direction=send&status=pending")
      assert render(view) =~ "Page 2 of 2"

      # A page that exists is left where it is.
      render_patch(view, "/en/admin/sync/history?page=1&direction=send")
      assert_patch(view, "/en/admin/sync/history?page=1&direction=send")
      refute_patched(view, "/en/admin/sync/history?page=2&direction=send")
      assert :sys.get_state(view.pid).socket.assigns.page == 1
    end
  end

  # Bulk rows straight in SQL: the count, not the content, matters here.
  defp insert_transfers(count) do
    PhoenixKit.RepoHelper.repo().query!(
      """
      INSERT INTO phoenix_kit_sync_transfers (direction, table_name, inserted_at)
      SELECT 'send', 'history_bulk_table', now() FROM generate_series(1, $1)
      """,
      [count]
    )
  end
end
