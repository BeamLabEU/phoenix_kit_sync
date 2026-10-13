defmodule PhoenixKitSync.Web.ReceiverPagingTest do
  use PhoenixKitSync.LiveCase

  # The receiver asks the sender for the next batch at the offset after the
  # records it got. This process stands in for the WebSocket client, so the
  # LiveView's next request lands here; Oban in manual mode takes the
  # import job without running it.

  setup do
    start_supervised!({Oban, repo: PhoenixKitSync.Test.Repo, testing: :manual})
    :ok
  end

  defp start_transfer(view, table) do
    ws_client = self()

    :sys.replace_state(view.pid, fn state ->
      assigns =
        Map.merge(state.socket.assigns, %{
          ws_client: ws_client,
          transferring: true,
          transfer_progress: %{
            status: :fetching,
            current_table: table,
            tables_pending: [table],
            tables_fetched: [],
            tables_done: 0,
            total_tables: 1,
            records_fetched: 0,
            jobs_queued: 0,
            pending_fetch: {table, 0}
          }
        })

      put_in(state.socket.assigns, assigns)
    end)
  end

  # Sends a batch and waits until the LiveView has handled it, so the
  # mailbox checks below need no timeout.
  defp batch(view, table, records, has_more, echo \\ 0, extra \\ %{}) do
    result = Map.merge(%{records: records, has_more: has_more, offset: echo}, extra)
    send(view.pid, {:sync_client, {:records, table, result}})

    _ = :sys.get_state(view.pid)
  end

  defp rows(n, from \\ 1), do: Enum.map(from..(from + n - 1), &%{"id" => &1})

  defp mount_transfer(conn) do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/sync/receive")
    start_transfer(view, "rx_table")
    view
  end

  test "the next batch starts after the records that arrived", %{conn: conn} do
    view = mount_transfer(conn)

    # Fewer than the receiver asked for, with more to come.
    batch(view, "rx_table", rows(3), true)

    assert_received {:"$websockex_cast", {:request_records, "rx_table", opts}}
    assert opts[:offset] == 3
  end

  test "a sender's position goes back with the next request, beside the offset", %{conn: conn} do
    view = mount_transfer(conn)

    batch(view, "rx_table", rows(3), true, 0, %{next_after: %{"id" => "3"}})

    assert_received {:"$websockex_cast", {:request_records, "rx_table", opts}}
    assert opts[:after] == %{"id" => "3"}
    assert opts[:offset] == 3
  end

  test "a sender that answers no position is followed by offset alone", %{conn: conn} do
    view = mount_transfer(conn)

    # A reply from before positions has no such key at all; a current
    # sender with a key that has no cursor answers nil.
    batch(view, "rx_table", rows(3), true)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", first}}
    assert first[:after] == nil
    assert first[:offset] == 3

    batch(view, "rx_table", rows(3, 4), true, 0, %{next_after: nil})
    assert_received {:"$websockex_cast", {:request_records, "rx_table", second}}
    assert second[:after] == nil
    assert second[:offset] == 6
  end

  test "the position of one page is not carried past a page without one", %{conn: conn} do
    view = mount_transfer(conn)

    batch(view, "rx_table", rows(3), true, 0, %{next_after: %{"id" => "3"}})
    assert_received {:"$websockex_cast", {:request_records, "rx_table", _first}}

    batch(view, "rx_table", rows(3, 4), true)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", second}}
    assert second[:after] == nil
    assert second[:offset] == 6
  end

  test "an empty batch ends the table", %{conn: conn} do
    view = mount_transfer(conn)

    batch(view, "rx_table", [], true)

    refute_received {:"$websockex_cast", {:request_records, _table, _opts}}
    assert :sys.get_state(view.pid).socket.assigns.transfer_progress.status == :completed
  end

  test "a sender that always echoes offset 0 still moves forward", %{conn: conn} do
    view = mount_transfer(conn)

    batch(view, "rx_table", rows(500), true, 0)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", first}}
    assert first[:offset] == 500

    batch(view, "rx_table", rows(500, 501), true, 0)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", second}}
    assert second[:offset] == 1_000

    batch(view, "rx_table", [], true, 0)
    refute_received {:"$websockex_cast", {:request_records, _table, _opts}}
    assert :sys.get_state(view.pid).socket.assigns.transfer_progress.status == :completed
  end

  test "a sender that says no more is read until an empty page", %{conn: conn} do
    view = mount_transfer(conn)

    # A short page the sender calls the last one, though it is not.
    batch(view, "rx_table", rows(3), false)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", opts}}
    assert opts[:offset] == 3

    progress = :sys.get_state(view.pid).socket.assigns.transfer_progress
    assert progress.jobs_queued == 1
    refute progress.status == :completed

    batch(view, "rx_table", [], false)
    refute_received {:"$websockex_cast", {:request_records, _table, _opts}}
    assert :sys.get_state(view.pid).socket.assigns.transfer_progress.status == :completed
  end

  test "a sender that answers the same page again ends the table instead of looping", %{
    conn: conn
  } do
    view = mount_transfer(conn)

    batch(view, "rx_table", rows(500), true)
    assert_received {:"$websockex_cast", {:request_records, "rx_table", first}}
    assert first[:offset] == 500

    # The offset was ignored: the page that came for 500 is the page for 0.
    batch(view, "rx_table", rows(500), true)

    refute_received {:"$websockex_cast", {:request_records, _table, _opts}}
    progress = :sys.get_state(view.pid).socket.assigns.transfer_progress
    assert progress.status == :completed
    # The repeated page is not imported a second time.
    assert progress.jobs_queued == 1
  end
end
