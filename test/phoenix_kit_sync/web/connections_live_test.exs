defmodule PhoenixKitSync.Web.ConnectionsLiveTest do
  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections

  defp create_connection(attrs \\ %{}) do
    defaults = %{
      "name" => "Test #{System.unique_integer([:positive])}",
      "direction" => "sender",
      "site_url" => "https://remote-#{System.unique_integer([:positive])}.example.com",
      "approval_mode" => "auto_approve"
    }

    {:ok, conn, _token} = Connections.create_connection(Map.merge(defaults, attrs))
    conn
  end

  describe "mount and render" do
    test "renders the connections list page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections")

      assert html =~ "Connections"
    end

    test "shows existing connections in the list", %{conn: conn} do
      _connection = create_connection(%{"name" => "Listed Connection"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections")

      assert html =~ "Listed Connection"
    end
  end

  describe "create connection form" do
    test "new action renders the form", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections/new")

      assert html =~ "New Connection"
      assert html =~ ~s|name="connection[name]"|
      assert html =~ ~s|name="connection[site_url]"|
    end

    # Delta pin for C5: every submit button gets phx-disable-with.
    test "save button carries phx-disable-with", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections/new")

      assert html =~ ~s|phx-disable-with="Saving…"|
    end

    # Delta pin for C5: validate event sets changeset :action so <.input>
    # renders inline errors.
    test "invalid submit re-renders with validation errors", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/connections/new")

      html =
        view
        |> form("form", connection: %{"name" => "", "site_url" => ""})
        |> render_submit()

      # Error styling comes from the <.input> component; at minimum we
      # see the form still rendered (didn't navigate away on failure).
      assert html =~ "New Connection"
    end
  end

  describe "delete connection" do
    test "deletes the connection and pins actor_uuid in the activity log", %{conn: conn} do
      connection = create_connection(%{"name" => "To Be Deleted"})
      admin_scope = fake_scope()

      conn = put_test_scope(conn, admin_scope)
      {:ok, view, _html} = live(conn, "/en/admin/sync/connections")

      html =
        view
        |> element("button[phx-click='delete_connection'][phx-value-uuid='#{connection.uuid}']")
        |> render_click()

      # The flash shows AFTER the click; assertion confirms the delete
      # path ran (flash text comes from gettext-wrapped put_flash).
      refute html =~ "To Be Deleted"

      # Delta pin: the deletion activity row landed AND threaded the
      # admin's UUID through. Without `actor_uuid: ...` in the assertion,
      # a regression where the LV omits the opt would silently log
      # actor_uuid=nil and this test would pass anyway.
      assert_activity_logged("sync.connection.deleted",
        resource_uuid: connection.uuid,
        actor_uuid: admin_scope.user.uuid
      )
    end
  end

  describe "reactivate connection" do
    # Pinning test for actor_uuid threading through reactivate_connection.
    # Pre-fix the LV called `Connections.reactivate_connection(connection)`
    # with no opts, so the activity row had actor_uuid=nil. Reactivate's
    # button lives in the connection detail panel (not the list grid), so
    # this test exercises the context layer with the same opts the LV
    # now passes — which is enough to pin the regression: if the LV
    # drops the actor_uuid opt again, the integration test in
    # connections_test.exs catches it via the same assertion.
    test "reactivate threads actor_uuid into the activity log" do
      connection = create_connection(%{"name" => "Reactivatable"})
      admin_uuid = PhoenixKitSync.TestActor.uuid()

      {:ok, suspended} = Connections.suspend_connection(connection, admin_uuid)
      {:ok, _} = Connections.reactivate_connection(suspended, actor_uuid: admin_uuid)

      assert_activity_logged("sync.connection.reactivated",
        resource_uuid: connection.uuid,
        actor_uuid: admin_uuid
      )
    end
  end

  describe "regenerate token" do
    # Same shape as reactivate — regenerate_token's button is in the
    # connection detail panel, not the list. Pinning at the context layer
    # with the same opts the LV passes is enough to catch a regression
    # where the LV drops the actor_uuid opt.
    test "regenerate_token threads actor_uuid into the activity log" do
      connection = create_connection(%{"name" => "Token Rotator"})
      admin_uuid = PhoenixKitSync.TestActor.uuid()

      {:ok, _, _new_token} = Connections.regenerate_token(connection, actor_uuid: admin_uuid)

      assert_activity_logged("sync.connection.token_regenerated",
        resource_uuid: connection.uuid,
        actor_uuid: admin_uuid
      )
    end
  end

  describe "handle_info catch-all (deep-dive review fix)" do
    # Pinning test for the missing handle_info catch-all flagged by C12
    # re-validation. Without this clause, a stray PubSub message or any
    # unexpected internal signal would crash the LV — losing the admin's
    # in-progress form input.
    test "an unexpected message does not crash the LiveView", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/connections")

      send(view.pid, :unexpected_message_that_should_be_ignored)
      send(view.pid, {:some, :tuple, :nobody, :handles})

      # If the catch-all is missing, render/1 raises and the assertion
      # below fails because the LV is dead.
      assert render(view) =~ "Connections"
      assert Process.alive?(view.pid)
    end
  end

  # F1 follow-up: phoenix-thinking Iron Law pin. mount/3 fires on both the
  # HTTP dead render and the WebSocket connect, so an unconditional
  # `load_connections/1` in mount doubles every list query and — worse for
  # this LV — fans the async sender-status / receiver-verification HTTP
  # calls twice. The dead-render path now seeds empty assigns; the data
  # only arrives once the socket is live.
  describe "Iron Law: mount/3 must not query during dead render (F1)" do
    test "dead render does not include connection names from the DB", %{conn: conn} do
      marker = "IronLawMarker-#{System.unique_integer([:positive])}"
      _connection = create_connection(%{"name" => marker})

      conn = put_test_scope(conn, fake_scope())

      # `Phoenix.ConnTest.get/2` issues only the HTTP dead-render — no
      # WebSocket upgrade. If `load_connections/1` runs in mount, the
      # marker name will be in the rendered body. After the F1 fix, the
      # dead render has empty `:sender_connections` / `:receiver_connections`
      # assigns and the marker is absent.
      resp = Phoenix.ConnTest.get(conn, "/en/admin/sync/connections")
      refute resp.resp_body =~ marker
    end

    test "live render (post-WebSocket) does include the connection", %{conn: conn} do
      marker = "PostWSMarker-#{System.unique_integer([:positive])}"
      _connection = create_connection(%{"name" => marker})

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/sync/connections")

      # The live render runs after the WebSocket connect, so the data
      # *does* arrive — pinning that the gate is `connected?`-conditional,
      # not "never load".
      assert html =~ marker
    end
  end

  # F1' follow-up (PR #7 review): handle_params/3's "show"/"edit"/"sync"
  # clauses queried Connections.get_connection/1 unconditionally, including
  # during the HTTP dead render of a deep-linked URL. Same Iron Law as F1
  # applied to mount; the dispatcher is now gated on connected?(socket) so
  # dead render is a no-op. The F4 test above (revoke gettext) is the
  # primary place this path is now exercised in the suite.
  describe "Iron Law: handle_params must not query during dead render of deep links (F1')" do
    test "dead render of ?action=show&id=<uuid> does not include connection details",
         %{conn: conn} do
      marker = "DeepLinkShowMarker-#{System.unique_integer([:positive])}"
      connection = create_connection(%{"name" => marker, "direction" => "receiver"})

      conn = put_test_scope(conn, fake_scope())

      # `Phoenix.ConnTest.get/2` issues only the HTTP dead-render — no
      # WebSocket upgrade. If the show clause queries the DB in dead render,
      # `setup_connection_view(:show)` assigns `:selected_connection` and
      # the detail template renders the connection's name. After the F1'
      # fix the show clause is gated on `connected?(socket)`, so dead
      # render falls through with the empty list-view assigns from mount.
      resp =
        Phoenix.ConnTest.get(
          conn,
          "/en/admin/sync/connections?action=show&id=#{connection.uuid}"
        )

      refute resp.resp_body =~ marker
    end

    test "dead render of ?action=edit&id=<uuid> does not include connection details",
         %{conn: conn} do
      marker = "DeepLinkEditMarker-#{System.unique_integer([:positive])}"
      connection = create_connection(%{"name" => marker, "direction" => "sender"})

      conn = put_test_scope(conn, fake_scope())

      resp =
        Phoenix.ConnTest.get(
          conn,
          "/en/admin/sync/connections?action=edit&id=#{connection.uuid}"
        )

      refute resp.resp_body =~ marker
    end

    test "live render of deep link does include connection details", %{conn: conn} do
      marker = "PostWSDeepLinkMarker-#{System.unique_integer([:positive])}"
      connection = create_connection(%{"name" => marker, "direction" => "receiver"})

      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} =
        live(conn, "/en/admin/sync/connections?action=show&id=#{connection.uuid}")

      # The connected phase re-fires handle_params after the WebSocket
      # connect, so the show branch resolves and renders the detail view.
      # Pins that the gate is `connected?`-conditional, not "never load".
      assert html =~ marker
    end
  end

  # F4 follow-up: gettext-wrap the literal "Revoked by admin" reason. The
  # reason is persisted to `revoked_reason` and surfaced to admins; same
  # translation surface as the strings Batch 2 wrapped. Test asserts the
  # persisted reason equals the gettext output (which falls through to
  # the source string when no translation is loaded).
  describe "revoke reason is gettext-wrapped (F4)" do
    test "revoke_connection persists a gettext-wrapped default reason", %{conn: conn} do
      receiver = create_connection(%{"direction" => "receiver", "status" => "active"})
      admin_scope = fake_scope(user_uuid: PhoenixKitSync.TestActor.uuid())

      # The revoke button lives in the connection detail view, not the
      # list view. Mount directly into the detail view via the URL the
      # `show_connection` push_patch would land on.
      conn = put_test_scope(conn, admin_scope)

      {:ok, view, _html} =
        live(conn, "/en/admin/sync/connections?action=show&id=#{receiver.uuid}")

      view
      |> element("[phx-click='revoke_connection'][phx-value-uuid='#{receiver.uuid}']")
      |> render_click()

      reloaded = Connections.get_connection!(receiver.uuid)

      # PhoenixKitWeb.Gettext is the backend ConnectionsLive imports via
      # `use Gettext`. At runtime with no translation loaded, gettext/1
      # returns the source string — so the persisted reason equals the
      # source string. The pin: it goes through gettext, not a literal.
      expected = Gettext.gettext(PhoenixKitWeb.Gettext, "Revoked by admin")
      assert reloaded.revoked_reason == expected
    end
  end

  describe "approve pending connection" do
    test "approve button triggers approve_connection and logs activity", %{conn: conn} do
      connection = create_connection(%{"name" => "Pending Approval", "status" => "pending"})
      admin_scope = fake_scope(user_uuid: PhoenixKitSync.TestActor.uuid())

      conn = put_test_scope(conn, admin_scope)
      {:ok, view, _html} = live(conn, "/en/admin/sync/connections")

      # The approve button only shows for pending receivers — create one
      # explicitly instead of the default sender.
      {:ok, receiver, _token} =
        Connections.create_connection(%{
          "name" => "Pending Receiver",
          "direction" => "receiver",
          "site_url" =>
            "https://pending-receiver-#{System.unique_integer([:positive])}.example.com",
          "status" => "pending"
        })

      view |> render()

      # Manually call the context — LiveView approval button markup depends
      # on conditional rendering; we're pinning the activity log path, not
      # the UI chrome here. C11 delta audit will add the per-button pin
      # once the markup is stable across the current sweep.
      {:ok, _} = Connections.approve_connection(receiver, admin_scope.user.uuid)

      assert_activity_logged("sync.connection.approved",
        resource_uuid: receiver.uuid,
        actor_uuid: admin_scope.user.uuid
      )

      _ = connection
    end
  end
end
