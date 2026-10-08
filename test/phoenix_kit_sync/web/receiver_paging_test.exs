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

  defp batch(view, table, records, has_more) do
    send(
      view.pid,
      {:sync_client, {:records, table, %{records: records, has_more: has_more, offset: 0}}}
    )
  end

  test "the next batch starts after the records that arrived", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/sync/receive")
    start_transfer(view, "rx_table")

    # Fewer than the receiver asked for, with more to come.
    batch(view, "rx_table", Enum.map(1..3, &%{"id" => &1}), true)

    assert_receive {:"$websockex_cast", {:request_records, "rx_table", opts}}
    assert opts[:offset] == 3
  end

  test "an empty batch ends the table", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _html} = live(conn, "/en/admin/sync/receive")
    start_transfer(view, "rx_table")

    batch(view, "rx_table", [], true)

    refute_receive {:"$websockex_cast", {:request_records, _table, _opts}}
    assert :sys.get_state(view.pid).socket.assigns.transfer_progress.status == :completed
  end
end
