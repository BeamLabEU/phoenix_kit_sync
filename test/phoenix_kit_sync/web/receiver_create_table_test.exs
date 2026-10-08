defmodule PhoenixKitSync.Web.ReceiverCreateTableTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Errors

  # Reaching the receiver's table details needs a live WebSocket session to
  # a sender, which the test router does not provide. The table and schema
  # it would have loaded are put on the socket directly; the event under
  # test is the receiver's own create_table.

  defp put_assigns(view, assigns) do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket, &Phoenix.Component.assign(&1, assigns))
    end)
  end

  test "a refused schema shows the translated reason, not the raw term", %{conn: conn} do
    {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), "/en/admin/sync/receive")

    put_assigns(view,
      selected_detail_table: "rc_created",
      detail_table_schema: %{
        "columns" => [%{"name" => "code", "type" => "text UNIQUE", "primary_key" => true}],
        "primary_key" => ["code"]
      }
    )

    html = render_click(view, "create_table", %{})

    assert has_element?(view, "#flash-error", Errors.message(:invalid_column_type))
    refute html =~ ":invalid_column_type"
  end
end
