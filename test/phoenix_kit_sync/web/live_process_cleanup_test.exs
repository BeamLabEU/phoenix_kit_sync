defmodule PhoenixKitSync.Web.LiveProcessCleanupTest do
  use PhoenixKitSync.LiveCase

  # Neither LiveView of the code-based flow has a terminate/2: what each
  # one holds is tied to its process, so it is released however the process
  # ends. These tests end it the way no callback sees, with a kill.

  setup %{conn: conn} do
    PhoenixKitSync.enable_system()
    # The LiveView is linked to this process through the test's proxy.
    Process.flag(:trap_exit, true)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "the sender's session is deleted when its LiveView is killed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/sync/send")
    render_click(view, "generate_code", %{})

    code = assigns(view).session.code
    assert {:ok, %{code: ^code}} = PhoenixKitSync.get_session(code)

    kill(view.pid)

    # The store handles the owner's DOWN in its own process; a call to it
    # returns after that message.
    _ = :sys.get_state(PhoenixKitSync.SessionStore)
    assert {:error, :not_found} = PhoenixKitSync.get_session(code)
  end

  test "the receiver's WebSocket client goes down when its LiveView is killed", %{conn: conn} do
    {:ok, session} = PhoenixKitSync.create_session(:send)
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    {:ok, view, _html} = live(conn, "/en/admin/sync/receive")

    view
    |> form("form", sender_url: "http://localhost:#{port}", connection_code: session.code)
    |> render_change()

    view |> element("form") |> render_submit()

    # The client is started in a message the LiveView sends itself.
    client =
      Enum.find_value(1..200, fn _attempt ->
        assigns(view).ws_client || (Process.sleep(10) && nil)
      end)

    assert is_pid(client)
    client_ref = Process.monitor(client)

    kill(view.pid)

    assert_receive {:DOWN, ^client_ref, :process, ^client, _reason}, 5_000
  end
end
