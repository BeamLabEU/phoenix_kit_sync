defmodule PhoenixKitSync.Web.ConnectionsLive.PreciseFilterTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.Test.StubRemote

  # Precise Transfer pulls only the IDs or the range the admin entered: the
  # filter goes to the sender with the pull, and an answer that ignored it
  # is not imported.

  @table "pf_lv_items"

  setup %{conn: conn} do
    PhoenixKit.RepoHelper.repo().query!(
      "CREATE TABLE IF NOT EXISTS #{@table} (id bigint PRIMARY KEY, label text)"
    )

    StubRemote.reset()
    on_exit(&StubRemote.reset/0)
    StubRemote.put_tables([%{"name" => @table, "row_count" => 4, "depends_on" => []}])

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url()
      })

    {:ok, conn: put_test_scope(conn, fake_scope()), connection: connection}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp wait_for(view, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> assigns(view) end)
    |> Enum.find(fn assigns ->
      fun.(assigns) or System.monotonic_time(:millisecond) > deadline or
        (Process.sleep(20) && false)
    end)
  end

  defp transfer_ids(conn, connection, ids),
    do: transfer(conn, connection, %{"mode" => "ids", "ids" => ids})

  defp transfer(conn, connection, filter) do
    {:ok, view, _html} =
      live(conn, "/en/admin/sync/connections?action=sync&id=#{connection.uuid}")

    wait_for(view, &(&1.sync_loading == false))
    render_click(view, "switch_sync_tab", %{"tab" => "details"})
    render_click(view, "select_detail_table", %{"table" => @table})
    render_change(view, "update_detail_filter", filter)
    render_click(view, "transfer_detail_table", %{})
    {view, wait_for(view, &(&1.sync_in_progress == false))}
  end

  test "the entered ids go to the sender and only those rows come in", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_data(@table, [%{"id" => 2, "label" => "b"}, %{"id" => 4, "label" => "d"}])
    StubRemote.put_response_extra(@table, %{"filtered" => true})

    {_view, assigns} = transfer_ids(conn, connection, "2, 4")

    assert %{"ids" => [2, 4]} = StubRemote.last_pull_body(@table)

    assert [%{table: @table, imported: 2, error_message: nil}] =
             assigns.sync_progress.table_results
  end

  test "an older sender that ignores the ids: the row says so", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_data(@table, for(id <- 1..4, do: %{"id" => id, "label" => "x"}))

    {view, assigns} = transfer_ids(conn, connection, "2")

    message = Errors.message(:sender_ignores_filters)

    assert [%{table: @table, imported: 0, error_message: ^message}] =
             assigns.sync_progress.table_results

    assert has_element?(view, ~s([data-table-error="#{@table}"]), "ignored the record filter")
  end

  test "uuids and other non-integer ids go as typed", %{conn: conn, connection: connection} do
    StubRemote.put_data(@table, [])
    StubRemote.put_response_extra(@table, %{"filtered" => true})
    uuid = "0192e0a4-5a6b-7c8d-9e0f-a1b2c3d4e5f6"

    transfer_ids(conn, connection, "#{uuid}, 01923abc-x, 42")

    assert %{"ids" => [^uuid, "01923abc-x", 42]} = StubRemote.last_pull_body(@table)
  end

  for {label, filter} <- [
        {"blank ids", %{"mode" => "ids", "ids" => " , "}},
        {"an empty range", %{"mode" => "range", "range_start" => "", "range_end" => ""}},
        {"a non-integer bound", %{"mode" => "range", "range_start" => "abc", "range_end" => ""}}
      ] do
    test "#{label} is refused before anything is pulled", %{conn: conn, connection: connection} do
      StubRemote.put_data(@table, for(id <- 1..4, do: %{"id" => id, "label" => "x"}))

      {view, assigns} = transfer(conn, connection, unquote(Macro.escape(filter)))

      message = Errors.message(:invalid_filter)
      assert [%{table: @table, error_message: ^message}] = assigns.sync_progress.table_results
      assert has_element?(view, ~s([data-table-error="#{@table}"]), "at least one ID")
      assert StubRemote.pull_count(@table) == 0
    end
  end
end
