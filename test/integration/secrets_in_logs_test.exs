defmodule PhoenixKitSync.Integration.SecretsInLogsTest.HostRoutes do
  @moduledoc false
  defmacro mount, do: PhoenixKitSync.Routes.generate("/pk")
end

defmodule PhoenixKitSync.Integration.SecretsInLogsTest.HostRouter do
  @moduledoc false
  # A router as a host has one: the module's public routes, mounted the way
  # core mounts them.
  use Phoenix.Router

  alias PhoenixKitSync.Integration.SecretsInLogsTest.HostRoutes

  require HostRoutes

  pipeline :phoenix_kit_api do
    plug(:accepts, ["json"])
  end

  HostRoutes.mount()
end

defmodule PhoenixKitSync.Integration.SecretsInLogsTest do
  use PhoenixKitSync.LiveCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitSync.Integration.SecretsInLogsTest.HostRouter
  alias PhoenixKitSync.SessionStore
  alias PhoenixKitSync.Web.SyncWebsock
  alias PhoenixKitSync.WebSocketClient
  alias PhoenixKitSync.Workers.ImportWorker

  # A session code opens a read of this site's database, and a token or a
  # download password does the same for a connection. None of them is
  # written to a log line, kept in a job or put in the activity log; these
  # tests take each path a real one travels and look for it afterwards.

  setup do
    PhoenixKitSync.enable_system()
    :ok
  end

  # The lines that would carry a secret are info and debug ones, below the
  # level the suite logs at: everything is logged while `fun` runs.
  defp capture_all(fun) do
    level = Logger.level()

    capture_log([level: :debug], fn ->
      Logger.configure(level: :debug)

      try do
        fun.()
      after
        Logger.configure(level: level)
      end
    end)
  end

  defp endpoint_url do
    "http://localhost:#{Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)}"
  end

  defp join(code) do
    {:ok, client} =
      WebSocketClient.start_link(
        url: endpoint_url(),
        code: code,
        caller: self(),
        receiver_info: %{"user_name" => "Receiver"}
      )

    assert_receive {:sync_client, :connected}, 5_000
    client
  end

  describe "a receiver joining over a real socket with a code" do
    test "what the session's owner is told carries no code" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      log =
        capture_all(fn ->
          client = join(session.code)

          assert_receive {:sync, {:receiver_joined, _pid, full_info}}, 5_000

          assert %{connection_info: %{request_path: _, remote_ip: _} = info} = full_info
          refute Map.has_key?(info, :query_string)
          refute inspect(full_info) =~ session.code

          {:ok, stored} = SessionStore.get(session.code)
          refute inspect(Map.delete(stored, :code)) =~ session.code

          WebSocketClient.disconnect(client)
        end)

      refute log =~ session.code
    end

    test "the Sender page logs no code when its receiver connects", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/send")
      view |> element("button[phx-click=generate_code]") |> render_click()

      [session] = Enum.filter(SessionStore.list_active(), &(&1.owner_pid == view.pid))

      log =
        capture_all(fn ->
          client = join(session.code)
          # The page has handled the join once it shows the receiver.
          assert render(view) =~ "Receiver"
          WebSocketClient.disconnect(client)
          _ = render(view)
        end)

      assert log =~ "Sync.Sender: Receiver connected"
      refute log =~ session.code
    end

    test "the Sender page logs nothing of a connection map handed to it", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/sync/send")
      view |> element("button[phx-click=generate_code]") |> render_click()

      log =
        capture_all(fn ->
          send(
            view.pid,
            {:sync,
             {:receiver_joined, self(),
              %{
                receiver_info: %{"user_name" => "R"},
                connection_info: %{
                  remote_ip: "203.0.113.7",
                  query_string: "code=SECRET77&password=hunter2secret&token=tok-secret-value"
                }
              }}}
          )

          _ = render(view)
        end)

      assert log =~ "Sync.Sender: Receiver connected"
      refute log =~ "SECRET77"
      refute log =~ "hunter2secret"
      refute log =~ "tok-secret-value"
    end
  end

  describe "the module's routes as a host mounts them" do
    @hash String.duplicate("ab12", 16)

    for action <- ~w(list-tables pull-data table-schema table-records verify-connection
                     delete-connection update-status get-connection-status register-connection) do
      test "#{action}: the router's line for the request is not written" do
        log =
          capture_all(fn ->
            Plug.Test.conn(:post, "/pk/sync/api/#{unquote(action)}", %{
              "auth_token_hash" => @hash,
              "table_name" => "t",
              "password" => "hunter2secret"
            })
            |> HostRouter.call(HostRouter.init([]))
          end)

        refute log =~ "Parameters:"
        refute without_queries(log) =~ @hash
        refute log =~ "hunter2secret"
      end
    end

    # The host's repo logs each query with its bind values at debug level,
    # the hash a connection is looked up by among them. That line is the
    # host's and stays; every other line is this module's to keep clean.
    defp without_queries(log) do
      log
      |> String.split("\n\n")
      |> Enum.reject(&(&1 =~ "QUERY OK" or &1 =~ "QUERY ERROR"))
      |> Enum.join("\n\n")
    end

    test "the socket's query (code, token, password) is not written" do
      log =
        capture_all(fn ->
          for query <- ["code=SECRET77", "token=tok-secret-value&password=hunter2secret"] do
            Plug.Test.conn(:get, "/pk/sync/websocket?" <> query)
            |> Plug.Conn.put_req_header("upgrade", "websocket")
            |> HostRouter.call(HostRouter.init([]))
          end
        end)

      refute log =~ "SECRET77"
      refute log =~ "tok-secret-value"
      refute log =~ "hunter2secret"
    end
  end

  describe "messages on the sockets" do
    test "the serving socket logs no topic of a message it does not know" do
      session = %{code: "SECRET77", direction: :send, owner_pid: self()}
      :ok = SessionStore.create(session)
      on_exit(fn -> SessionStore.delete("SECRET77") end)
      {:ok, state} = SyncWebsock.init(auth_type: :session, code: "SECRET77", session: session)
      frame = Jason.encode!([nil, "1", "transfer:SECRET77", "request:unknown", %{"a" => 1}])

      log =
        capture_all(fn ->
          assert {:ok, _state} =
                   SyncWebsock.handle_in({frame, [opcode: :text]}, %{state | joined: true})
        end)

      assert log =~ "Unknown message"
      refute log =~ "SECRET77"
    end

    test "the client logs no topic of a message it does not know" do
      state = %WebSocketClient{
        url: "ws://example.com",
        code: "SECRET77",
        caller: self(),
        receiver_info: %{},
        ref_counter: 0,
        pending_refs: %{},
        joined: true,
        heartbeat_ref: nil
      }

      frame = Jason.encode!([nil, nil, "transfer:SECRET77", "some:event", %{"a" => 1}])

      log =
        capture_all(fn ->
          assert {:ok, _state} = WebSocketClient.handle_frame({:text, frame}, state)
        end)

      assert log =~ "unknown event"
      refute log =~ "SECRET77"
    end
  end

  test "SQL debug logging cannot expose a connection's credential hash" do
    token = "review-credential-#{System.unique_integer([:positive])}"
    hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

    log =
      capture_all(fn ->
        assert {:ok, connection, ^token} =
                 PhoenixKitSync.Connections.create_connection(%{
                   "name" => "Debug logging",
                   "site_url" => "https://logging-review.example.com",
                   "direction" => "sender",
                   "auth_token" => token,
                   "status" => "active"
                 })

        assert PhoenixKitSync.Connections.find_by_hash_and_direction(hash, "sender").uuid ==
                 connection.uuid

        assert PhoenixKitSync.Connections.find_by_site_url_and_hash(
                 connection.site_url,
                 hash,
                 "sender"
               ).uuid == connection.uuid

        assert {:ok, _} =
                 PhoenixKitSync.Connections.update_connection(connection, %{
                   download_password: token
                 })
      end)

    refute log =~ token
    refute log =~ hash
    refute log =~ String.slice(hash, 0, 8)
  end

  test "a driver error and SQL debug logging cannot expose record values" do
    PhoenixKit.RepoHelper.repo().query!(
      "CREATE TABLE review_log_rows (id bigint PRIMARY KEY, value date)"
    )

    private_value = "private-password-value-#{System.unique_integer([:positive])}"

    log =
      capture_all(fn ->
        assert :ok =
                 ImportWorker.perform(%Oban.Job{
                   args: %{
                     "table" => "review_log_rows",
                     "records" => [%{"id" => 1, "value" => private_value}],
                     "strategy" => "skip"
                   }
                 })
      end)

    assert log =~ "failed"
    refute log =~ private_value
  end

  describe "ImportWorker and the session code it was given" do
    @table "sil_rows"

    setup do
      PhoenixKit.RepoHelper.repo().query!(
        "CREATE TABLE #{@table} (id bigint PRIMARY KEY, label text)"
      )

      :ok
    end

    defp perform(changeset) do
      args = changeset |> Ecto.Changeset.get_change(:args) |> Jason.encode!() |> Jason.decode!()

      {args,
       capture_all(fn ->
         send(self(), ImportWorker.perform(%Oban.Job{args: args}))
       end)}
    end

    test "a completed batch: not in the job, the log or the activity row" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      job = ImportWorker.create_job(@table, [%{"id" => 1, "label" => "a"}], :skip, session.code)

      {args, log} = perform(job)
      assert_received :ok

      refute Jason.encode!(args) =~ session.code
      refute log =~ session.code
      assert log =~ "Completed import for #{@table}"

      activity =
        assert_activity_logged("sync.import.batch_completed",
          metadata_has: %{"table_name" => @table}
        )

      refute Map.has_key?(activity.metadata, "session_code")
      refute Jason.encode!(activity.metadata) =~ session.code
      assert activity.metadata["session_ref"] == args["session_ref"]
    end

    test "a failed batch: not in the log" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      job =
        ImportWorker.create_job("phoenix_kit_settings", [%{"id" => 1}], :skip, session.code)

      {_args, log} = perform(job)
      assert_received {:error, :table_excluded}

      assert log =~ "Failed import"
      refute log =~ session.code
    end

    test "a job enqueued with the code itself in its args does not log or record it" do
      args = %{
        "table" => @table,
        "records" => [%{"id" => 2, "label" => "b"}],
        "strategy" => "skip",
        "session_code" => "OLDCODE7"
      }

      log =
        capture_all(fn ->
          assert :ok = ImportWorker.perform(%Oban.Job{args: args})
        end)

      refute log =~ "OLDCODE7"

      activity =
        assert_activity_logged("sync.import.batch_completed",
          metadata_has: %{"table_name" => @table}
        )

      refute Jason.encode!(activity.metadata) =~ "OLDCODE7"
    end
  end
end
