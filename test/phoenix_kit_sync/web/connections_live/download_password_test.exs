defmodule PhoenixKitSync.Web.ConnectionsLive.DownloadPasswordTest do
  use PhoenixKitSync.LiveCase

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.Transfer

  # A sender connection with a download password refuses every REST request
  # that does not carry it. The receiving admin types it on the sync page;
  # it is held for that page, sent with each request and written nowhere.
  # Both ends are this module: the receiver pulls from the test endpoint,
  # which reads the same database, and :overwrite writes each pulled row
  # back onto itself, counted by a trigger.

  @table "pw_rows"
  @password "correct-horse-7f3a9c"
  @wrong "wrong-guess-51b2e8"

  setup %{conn: conn} do
    PhoenixKitSync.enable_system()
    repo().query!("CREATE TABLE #{@table} (id int PRIMARY KEY, writes int NOT NULL DEFAULT 0)")
    repo().query!("INSERT INTO #{@table} (id) SELECT generate_series(1, 7)")

    repo().query!("""
    CREATE FUNCTION pw_rows_write() RETURNS trigger AS $$
    BEGIN
      NEW.writes := OLD.writes + 1;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    repo().query!(
      "CREATE TRIGGER pw_rows_writes BEFORE UPDATE ON #{@table} " <>
        "FOR EACH ROW EXECUTE FUNCTION pw_rows_write()"
    )

    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    {:ok, sender, token} =
      Connections.create_connection(%{
        "name" => "Protected sender",
        "direction" => "sender",
        "site_url" => "https://receiver-#{System.unique_integer([:positive])}.example.com",
        "status" => "active",
        "allowed_tables" => [@table],
        # Three rows a page, so the pull has continuation pages to carry
        # the password on as well.
        "max_records_per_request" => 3,
        "download_password" => @password
      })

    {:ok, receiver, _token} =
      Connections.create_connection(%{
        "name" => "Receiver side",
        "direction" => "receiver",
        "site_url" => "http://localhost:#{port}",
        "auth_token" => token,
        "status" => "active",
        "default_conflict_strategy" => "overwrite"
      })

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: PhoenixKitSync.TestActor.uuid())),
     sender: sender,
     receiver: receiver}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp wait_for(view, fun) do
    Enum.find_value(1..500, fn _attempt ->
      assigns = assigns(view)
      if fun.(assigns), do: assigns, else: Process.sleep(10) && nil
    end) || flunk("the page did not settle")
  end

  defp open_sync_page(conn, receiver) do
    {:ok, view, _html} = live(conn, "/en/admin/sync/connections?action=sync&id=#{receiver.uuid}")
    wait_for(view, &(&1.sync_loading == false))
    view
  end

  defp submit_password(view, password) do
    view |> form("#sync-password-form", %{"password" => password}) |> render_submit()
    wait_for(view, &(&1.sync_loading == false))
  end

  defp writes do
    %{rows: rows} = repo().query!("SELECT writes, count(*) FROM #{@table} GROUP BY writes")
    Map.new(rows, &List.to_tuple/1)
  end

  test "the page asks for the password, refuses a wrong one, and pulls with the right one", %{
    conn: conn,
    receiver: receiver
  } do
    log =
      capture_log([level: :debug], fn ->
        # Without a password: nothing is listed, and the page asks.
        view = open_sync_page(conn, receiver)

        assert assigns(view).sync_tables == []
        assert has_element?(view, ~s|#sync-password-form input[type="password"][name="password"]|)
        assert render(view) =~ "This connection asks for its download password"

        # A wrong one: the translated refusal, and the field again.
        submit_password(view, @wrong)

        assert assigns(view).sync_tables == []
        assert has_element?(view, ".alert-error", Errors.message(:invalid_password))
        assert has_element?(view, "#sync-password-form")
        assert assigns(view).sync_password == nil

        # The right one: the sender's tables, and no field.
        submit_password(view, @password)

        assert Enum.map(assigns(view).sync_tables, & &1.name) == [@table]
        refute has_element?(view, "#sync-password-form")
        refute has_element?(view, ".alert-error")

        # Neither attempt is in the page.
        html = render(view)
        refute html =~ @password
        refute html =~ @wrong

        # The pull, three pages of it, carries the password too.
        render_click(view, "toggle_table", %{"table" => @table})
        render_click(view, "execute_sync", %{})
        done = wait_for(view, &(&1.sync_in_progress == false and &1.sync_progress != nil))

        assert [%{table: @table, imported: 7, errors: 0, error_message: nil}] =
                 done.sync_progress.table_results

        assert writes() == %{1 => 7}
      end)

    # The log did record the run, events and requests included.
    assert log =~ "set_sync_password"
    assert log =~ @table
    refute log =~ @password
    refute log =~ @wrong

    # Nothing kept it: not the activity feed, not a transfer, not a connection.
    for table <-
          ~w(phoenix_kit_activities phoenix_kit_sync_transfers phoenix_kit_sync_connections) do
      %{rows: [[stored]]} =
        repo().query!("SELECT coalesce(string_agg(t::text, ' '), '') FROM #{table} t")

      refute stored =~ @password, "#{table} holds the password"
      refute stored =~ @wrong, "#{table} holds the wrong password"
    end
  end

  test "the preview and the schema of the Precise Transfer tab carry it as well", %{
    receiver: receiver
  } do
    for request <- [
          &ConnectionNotifier.fetch_sender_tables(receiver, &1),
          &ConnectionNotifier.fetch_table_schema(receiver, @table, &1),
          &ConnectionNotifier.fetch_table_records(receiver, @table, &1),
          &ConnectionNotifier.pull_table_data(receiver, @table, &1)
        ] do
      assert {:error, :invalid_password} = request.([])
      assert {:error, :invalid_password} = request.(password: @wrong)
      assert {:error, :invalid_password} = request.(password: "")
      assert {:ok, _answer} = request.(password: @password)
    end
  end

  test "a pull refused for its password closes its transfer without the password in it", %{
    receiver: receiver
  } do
    assert {:error, :invalid_password} =
             ConnectionNotifier.pull_table_data(receiver, @table, password: @wrong)

    transfer = repo().one!(from(t in Transfer, where: t.direction == "receive"))
    assert transfer.status == "failed"
    refute transfer.error_message =~ @wrong
    assert writes() == %{0 => 7}
  end

  test "a connection without a password is pulled as before, and never asked", %{
    conn: conn,
    sender: sender,
    receiver: receiver
  } do
    {:ok, _sender} = Connections.update_connection(sender, %{"download_password" => nil})
    repo().query!("UPDATE phoenix_kit_sync_connections SET download_password_hash = NULL")

    view = open_sync_page(conn, receiver)

    assert Enum.map(assigns(view).sync_tables, & &1.name) == [@table]
    refute has_element?(view, "#sync-password-form")
  end

  test "leaving the sync page drops the password", %{conn: conn, receiver: receiver} do
    view = open_sync_page(conn, receiver)
    submit_password(view, @password)
    assert assigns(view).sync_password == @password

    render_click(view, "cancel", %{})

    assert assigns(view).sync_password == nil
  end
end
