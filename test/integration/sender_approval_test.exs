defmodule PhoenixKitSync.Integration.SenderApprovalTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote

  # A sender connection made on this site stays pending until an admin of
  # this site clicks Approve. One test per path that could change its
  # status: none but the click activates it.

  setup do
    PhoenixKitSync.enable_system()
    StubRemote.reset()
    on_exit(&StubRemote.reset/0)
    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  defp status_of(%{uuid: uuid}), do: Connections.get_connection!(uuid).status

  defp admin_conn(conn),
    do: put_test_scope(conn, fake_scope(user_uuid: PhoenixKitSync.TestActor.uuid()))

  defp pending_sender(attrs \\ %{}) do
    {:ok, connection, token} =
      Connections.create_connection(
        Map.merge(
          %{
            "name" => "Outgoing #{System.unique_integer([:positive])}",
            "direction" => "sender",
            "site_url" => "#{StubRemote.url()}/peer-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    {connection, token}
  end

  describe "creating it in the form" do
    test "is pending, says so, and shows the badge and the Approve button", %{conn: conn} do
      {:ok, view, _html} = live(admin_conn(conn), "/en/admin/sync/connections/new")
      url = "#{StubRemote.url()}/form-#{System.unique_integer([:positive])}"

      # A status smuggled into the submit is not taken from the form.
      html =
        view
        |> form("form", connection: %{"name" => "Outgoing", "site_url" => url})
        |> render_submit(%{"connection" => %{"status" => "active"}})

      connection = repo().get_by!(Connection, site_url: url)
      assert connection.direction == "sender"
      assert connection.status == "pending"

      assert html =~ "It is pending: approve it in the list before the other site can use it"

      row = view |> element("tr", url) |> render()
      assert row =~ ~r/badge[^>]*>\s*Pending\s*</
      assert row =~ ~s|phx-click="approve_connection"|
      assert row =~ ~s|phx-value-uuid="#{connection.uuid}"|
    end

    test "editing it cannot set a status", %{conn: conn} do
      {connection, _token} = pending_sender()

      {:ok, view, _html} =
        live(admin_conn(conn), "/en/admin/sync/connections?action=edit&id=#{connection.uuid}")

      render_submit(view, "save", %{"connection" => %{"name" => "Renamed", "status" => "active"}})

      reloaded = Connections.get_connection!(connection.uuid)
      assert reloaded.name == "Renamed"
      assert reloaded.status == "pending"
    end

    test "the Approve click is what activates it", %{conn: conn} do
      {connection, _token} = pending_sender()
      {:ok, view, _html} = live(admin_conn(conn), "/en/admin/sync/connections")

      view
      |> element(~s|button[phx-click="approve_connection"][phx-value-uuid="#{connection.uuid}"]|)
      |> render_click()

      assert status_of(connection) == "active"
    end
  end

  test "no approval_mode activates it" do
    for mode <- ~w(auto_approve require_approval per_table) do
      {connection, _token} = pending_sender(%{"approval_mode" => mode})
      assert connection.status == "pending", mode
    end
  end

  test "the peer answering its registration with an active row does not activate it" do
    {connection, token} = pending_sender()

    StubRemote.put_registration(%{
      success: true,
      message: "Registered",
      connection_status: "active",
      connection_uuid: UUIDv7.generate()
    })

    assert {:ok, %{success: true}} = ConnectionNotifier.notify_remote_site(connection, token)

    reloaded = Connections.get_connection!(connection.uuid)
    assert reloaded.status == "pending"
    assert reloaded.metadata["remote_notification"]["notification_success"] == true
  end

  test "under auto_accept, the peer registering back creates a receiver row and leaves it pending",
       %{conn: conn} do
    {connection, _token} = pending_sender()
    PhoenixKitSync.set_incoming_mode("auto_accept")
    on_exit(fn -> PhoenixKitSync.set_incoming_mode("require_approval") end)

    response =
      post(conn, "/sync/api/register-connection", %{
        "sender_url" => connection.site_url,
        "connection_name" => "Back",
        "auth_token" => "peer-token-#{System.unique_integer([:positive])}"
      })

    assert json_response(response, 200)["connection_status"] == "active"
    assert status_of(connection) == "pending"
  end

  test "get-connection-status is a read", %{conn: conn} do
    {connection, token} = pending_sender()

    response =
      post(conn, "/sync/api/get-connection-status", %{
        "receiver_url" => connection.site_url,
        "auth_token_hash" => token_hash(token)
      })

    assert json_response(response, 200)["status"] == "pending"
    assert status_of(connection) == "pending"
  end

  test "update-status from the peer never finds a sender row", %{conn: conn} do
    {connection, token} = pending_sender()

    response =
      post(conn, "/sync/api/update-status", %{
        "sender_url" => connection.site_url,
        "auth_token_hash" => token_hash(token),
        "status" => "active"
      })

    assert json_response(response, 404)
    assert status_of(connection) == "pending"
  end

  test "the peer saying it lost the connection suspends it, never activates it", %{conn: conn} do
    {connection, _token} = pending_sender()
    {:ok, view, _html} = live(admin_conn(conn), "/en/admin/sync/connections")

    send(view.pid, {:receiver_connection_severed, connection.uuid})
    render(view)

    assert status_of(connection) == "suspended"
  end
end
