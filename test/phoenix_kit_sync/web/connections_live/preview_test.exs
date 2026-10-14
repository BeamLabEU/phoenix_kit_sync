defmodule PhoenixKitSync.Web.ConnectionsLive.PreviewTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SyncableTable
  alias PhoenixKitSync.Test.StubRemote

  # Every `table-records` answer spends one of the sender's downloads, so
  # the sync page asks for a preview only when the admin clicks for one.
  # And a sender over the connection's requests per minute makes the page
  # say it is waiting rather than look frozen.

  @table SyncableTable.name()

  setup %{conn: conn} do
    SyncableTable.insert!()
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    StubRemote.put_tables([%{"name" => @table, "row_count" => 2, "depends_on" => []}])
    StubRemote.put_data(@table, [%{"id" => 1}, %{"id" => 2}])

    StubRemote.put_schema(@table, %{
      "table_name" => @table,
      "columns" => [%{"column_name" => "id", "data_type" => "bigint", "is_nullable" => "NO"}],
      "primary_key" => ["id"]
    })

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "status" => "active",
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

  defp open_sync_page(conn, connection) do
    {:ok, view, _html} =
      live(conn, "/en/admin/sync/connections?action=sync&id=#{connection.uuid}")

    wait_for(view, &(&1.sync_loading == false))
    view
  end

  test "mounting, refreshing and selecting a table ask the sender for no rows", %{
    conn: conn,
    connection: connection
  } do
    view = open_sync_page(conn, connection)

    render_click(view, "refresh_tables", %{})
    wait_for(view, &(&1.sync_loading == false))

    render_click(view, "switch_sync_tab", %{"tab" => "details"})
    render_click(view, "select_detail_table", %{"table" => @table})
    wait_for(view, &(&1.loading_schema == false))

    assert assigns(view).detail_table_schema
    assert StubRemote.request_count("list-tables") == 2
    assert StubRemote.request_count("table-schema") == 1
    assert StubRemote.request_count("table-records") == 0
    assert assigns(view).detail_preview == nil

    assert has_element?(
             view,
             ~s|button#preview-detail-records[phx-click="preview_detail_records"][phx-disable-with]|
           )

    assert render(view) =~ "A preview counts as one download on the sending site."
  end

  test "clicking Preview rows asks for exactly one page of rows", %{
    conn: conn,
    connection: connection
  } do
    view = open_sync_page(conn, connection)
    render_click(view, "switch_sync_tab", %{"tab" => "details"})
    render_click(view, "select_detail_table", %{"table" => @table})
    wait_for(view, &(&1.loading_schema == false))

    view |> element("#preview-detail-records") |> render_click()
    wait_for(view, &(&1.loading_preview == false))

    assert StubRemote.request_count("table-records") == 1
    assert %{records: [_, _]} = assigns(view).detail_preview
  end

  test "a rate-limited sender shows the wait, then the tables", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_rate_limited("list-tables", 1, "1")

    {:ok, view, _html} =
      live(conn, "/en/admin/sync/connections?action=sync&id=#{connection.uuid}")

    wait_for(view, &(&1.sync_rate_limited != nil))
    assert render(view) =~ "Rate limited by the sender, retrying in 1 s"

    wait_for(view, &(&1.sync_loading == false and &1.sync_rate_limited == nil), 5_000)
    assert [_] = assigns(view).sync_tables
    refute has_element?(view, "#sync-rate-limited")
    assert StubRemote.request_count("list-tables") == 2
  end
end
