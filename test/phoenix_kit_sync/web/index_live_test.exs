defmodule PhoenixKitSync.Web.IndexLiveTest do
  use PhoenixKitSync.LiveCase

  describe "mount and render" do
    test "renders the sync overview dashboard", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync")

      # The Index LV is the entry point for the sync admin section. The
      # text content is largely fixed; the smoke test verifies mount
      # doesn't crash and the cards/explainer block render.
      assert html =~ "DB Sync"
      assert html =~ "Manage Connections"
      assert html =~ "Transfer History"
    end
  end

  describe "rendered copy" do
    test "does not name the kit", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync")

      refute html =~ "PhoenixKit"
      assert html =~ "Sync data between sites"
    end
  end

  describe "live refresh" do
    alias PhoenixKitSync.Connections

    defp stats(view), do: :sys.get_state(view.pid).socket.assigns.stats

    test "the connection counts follow connections created, changed and deleted elsewhere", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync")
      assert %{total_senders: 0, active_senders: 0} = stats(view)

      {:ok, connection, _token} =
        Connections.create_connection(%{
          "name" => "Live",
          "direction" => "sender",
          "site_url" => "https://live-#{System.unique_integer([:positive])}.example.com"
        })

      assert %{total_senders: 1, active_senders: 0} = stats(view)

      {:ok, active} = Connections.approve_connection(connection, actor_uuid: nil)
      assert %{total_senders: 1, active_senders: 1} = stats(view)

      {:ok, _} = Connections.delete_connection(active)
      assert %{total_senders: 0, active_senders: 0} = stats(view)
    end
  end
end
