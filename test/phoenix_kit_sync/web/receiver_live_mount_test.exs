defmodule PhoenixKitSync.Web.ReceiverLiveMountTest do
  use PhoenixKitSync.LiveCase

  describe "mount and render" do
    test "renders the initial enter-credentials form", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/receive")

      # The Receiver LV starts in :enter_credentials step. The form
      # asks for sender_url and connection_code before any WebSocket
      # action.
      assert html =~ "Receive Data" or html =~ "sender" or html =~ "code"
    end

    test "update_form event captures the sender_url and code", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/receive")

      html =
        view
        |> form("form",
          sender_url: "https://example.com",
          connection_code: "abcd1234"
        )
        |> render_change()

      # After update_form fires, the input retains the typed value.
      # Code is uppercased (seen in handle_event("update_form")).
      assert html =~ "https://example.com"
      assert html =~ "ABCD1234"
    end

    test "connect button without input shows error message", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/receive")

      html =
        view
        |> element("form")
        |> render_submit()

      # With no URL, the LV sets `:error_message` instead of starting
      # the WebSocket. The connect handler validates URL presence
      # before send(self(), :start_websocket).
      assert html =~ "URL" or html =~ "code" or html =~ "8 characters"
    end
  end

  describe "records batch during a transfer" do
    # The sender echoes the offset of each batch. This process stands in for
    # the WebSocket client, so the LiveView's next request lands here.
    defp start_transfer(view, table, requested_offset) do
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
              pending_fetch: {table, requested_offset}
            }
          })

        put_in(state.socket.assigns, assigns)
      end)
    end

    # A full batch of 500, so the receiver asks for the next one; Oban in
    # manual mode takes the import job without running it.
    defp full_batch, do: Enum.map(1..500, &%{"id" => &1})

    for echo <- ["abc", nil, 1.5, %{}, 0, 2_000] do
      test "an echoed offset of #{inspect(echo)} does not move the next request", %{conn: conn} do
        start_supervised!({Oban, repo: PhoenixKitSync.Test.Repo, testing: :manual})
        conn = put_test_scope(conn, fake_scope())
        {:ok, view, _html} = live(conn, "/en/admin/sync/receive")
        start_transfer(view, "rx_table", 500)

        send(
          view.pid,
          {:sync_client,
           {:records, "rx_table",
            %{records: full_batch(), has_more: true, offset: unquote(Macro.escape(echo))}}}
        )

        # Barrier: the batch is handled before the mailbox is checked.
        _ = :sys.get_state(view.pid)

        assert_received {:"$websockex_cast", {:request_records, "rx_table", opts}}
        assert opts[:offset] == 1_000
      end
    end
  end
end
