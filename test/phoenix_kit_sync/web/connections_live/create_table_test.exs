defmodule PhoenixKitSync.Web.ConnectionsLive.CreateTableTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.StubRemote

  # Precise Transfer > Create Table builds the local table from the schema
  # the sender's table-schema API returns. That API describes columns as
  # column_name / data_type / is_nullable; newer senders add primary_key.

  @table "ct_remote_only"

  setup %{conn: conn} do
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    StubRemote.put_tables([%{"name" => @table, "row_count" => 1, "depends_on" => []}])

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

  defp open_table_details(conn, connection) do
    {:ok, view, _html} =
      live(conn, "/en/admin/sync/connections?action=sync&id=#{connection.uuid}")

    wait_for(view, &(&1.sync_loading == false))
    render_click(view, "switch_sync_tab", %{"tab" => "details"})
    render_click(view, "select_detail_table", %{"table" => @table})
    wait_for(view, &(&1.loading_schema == false))
    view
  end

  defp column(name, type, nullable) do
    %{
      "column_name" => name,
      "data_type" => type,
      "is_nullable" => if(nullable, do: "YES", else: "NO"),
      "column_default" => nil,
      "character_maximum_length" => nil
    }
  end

  test "creates the table, with its primary key, from a sender that sends one", %{
    conn: conn,
    connection: connection
  } do
    StubRemote.put_schema(@table, %{
      "table_name" => @table,
      "columns" => [column("code", "text", false), column("note", "text", true)],
      "primary_key" => ["code"]
    })

    view = open_table_details(conn, connection)
    refute assigns(view).local_table_exists

    # The page reads the normalised shape, whatever the sender sent.
    assert Enum.map(assigns(view).detail_table_schema["columns"], & &1["name"]) == [
             "code",
             "note"
           ]

    render_click(view, "create_detail_table", %{})

    assert SchemaInspector.table_exists?(@table)
    assert {:ok, ["code"]} = SchemaInspector.get_primary_key(@table)
    assert assigns(view).local_table_exists
  end

  test "an older sender's schema without primary_key is refused, saying why", %{
    conn: conn,
    connection: connection
  } do
    # Created without a key, the table could never be pulled into.
    StubRemote.put_schema(@table, %{
      "table_name" => @table,
      "columns" => [column("code", "text", false)]
    })

    view = open_table_details(conn, connection)
    render_click(view, "create_detail_table", %{})

    assert has_element?(view, "#flash-error", Errors.message(:schema_without_primary_key))
    refute SchemaInspector.table_exists?(@table)
  end

  test "a refused schema shows the translated reason", %{conn: conn, connection: connection} do
    StubRemote.put_schema(@table, %{
      "table_name" => @table,
      "columns" => [column("code", "text UNIQUE", false)],
      "primary_key" => ["code"]
    })

    view = open_table_details(conn, connection)
    html = render_click(view, "create_detail_table", %{})

    assert has_element?(view, "#flash-error", Errors.message(:invalid_column_type))
    refute html =~ ":invalid_column_type"
    refute SchemaInspector.table_exists?(@table)
  end
end
