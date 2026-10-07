defmodule PhoenixKitSync.Web.ConnectionsLive.PullSyncTest do
  use PhoenixKitSync.LiveCase

  import Ecto.Query

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # The "Sync data" page pulls the selected tables one by one in a
  # supervised task. Whatever happens inside that task, its result has to
  # reach the LiveView: otherwise `sync_in_progress` never clears and the
  # page stays stuck on the progress bar.

  @parents "cpk_lv_parents"
  @tree "cpk_lv_tree"

  setup %{conn: conn} do
    repo().query!("CREATE TABLE IF NOT EXISTS #{@parents} (code text PRIMARY KEY, name text)")

    repo().query!("""
    CREATE TABLE IF NOT EXISTS #{@tree} (
      code text PRIMARY KEY,
      parent_code text REFERENCES #{@tree}(code),
      owner_code text REFERENCES #{@parents}(code)
    )
    """)

    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    StubRemote.put_tables([
      %{"name" => @tree, "row_count" => 1, "depends_on" => [@tree, @parents]},
      %{"name" => @parents, "row_count" => 1, "depends_on" => []}
    ])

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url()
      })

    {:ok, conn: put_test_scope(conn, fake_scope()), connection: connection}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

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

  defp run_sync(view) do
    render_click(view, "select_all_tables", %{})
    render_click(view, "execute_sync", %{})
    wait_for(view, &(&1.sync_in_progress == false))
  end

  defp in_progress_transfers do
    repo().aggregate(from(t in Transfer, where: t.status == "in_progress"), :count)
  end

  test "a self-referencing table is pulled once, after the tables it depends on", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_data(@parents, [%{"code" => "p1", "name" => "a"}])
    StubRemote.put_data(@tree, [%{"code" => "t1", "parent_code" => nil}])

    view = open_sync_page(conn, connection)
    assigns = run_sync(view)

    refute assigns.sync_in_progress
    assert assigns.sync_progress.total == 2
    assert Enum.map(assigns.sync_progress.table_results, & &1.table) == [@parents, @tree]
  end

  test "an import that raises still reports back and closes its transfer", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_data(@parents, ["not a record"])
    StubRemote.put_data(@tree, [%{"code" => "t1", "parent_code" => nil}])

    view = open_sync_page(conn, connection)
    assigns = run_sync(view)

    refute assigns.sync_in_progress
    assert assigns.sync_progress.status == :completed

    assert [%{table: @parents, error_message: message}, %{table: @tree, imported: 1}] =
             assigns.sync_progress.table_results

    assert is_binary(message)
    refute message =~ "not a record"
    assert in_progress_transfers() == 0
  end

  test "a crash before the transfer exists still reports back to the page", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_data(@parents, [])
    StubRemote.put_data(@tree, [])

    view = open_sync_page(conn, connection)
    # The transfer changeset rejects an unknown strategy, so the pull
    # crashes on creating its transfer, before any import starts.
    render_change(view, "change_conflict_strategy", %{"strategy" => "bogus"})
    assigns = run_sync(view)

    refute assigns.sync_in_progress
    assert assigns.sync_progress.status == :completed

    assert [%{table: @parents, error_message: m1}, %{table: @tree, error_message: m2}] =
             assigns.sync_progress.table_results

    assert is_binary(m1) and is_binary(m2)
    assert in_progress_transfers() == 0
  end
end
