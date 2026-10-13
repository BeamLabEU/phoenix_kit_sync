defmodule PhoenixKitSync.Integration.WebSocketClientTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Test.Repo, as: TestRepo
  alias PhoenixKitSync.WebSocketClient

  setup do
    # The Bandit listener + WebSockex client spawn separate processes
    # that need to see this test's sandbox transaction. Shared mode +
    # making sure the module is enabled in this transaction.
    Sandbox.mode(TestRepo, {:shared, self()})
    PhoenixKitSync.enable_system()
    :ok
  end

  # Self-loop tests: the receiver-side WebSocketClient connects to the
  # sender-side SocketPlug → SyncWebsock → SyncChannel running on the
  # SAME test endpoint. No second OS process needed; just a real
  # WebSocket round-trip through localhost:test_port.

  defp test_url do
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)
    "ws://localhost:#{port}"
  end

  describe "start_link/1 — connect with valid session code" do
    test "joins and emits :tables when request_tables/1 is called" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, client} =
        WebSocketClient.start_link(url: test_url(), code: session.code, caller: self())

      # Wait for the join to complete.
      assert_receive {:sync_client, :connected}, 5_000

      WebSocketClient.request_tables(client)

      assert_receive {:sync_client, {:tables, tables}}, 5_000
      assert is_list(tables)

      WebSocketClient.disconnect(client)
    end

    test "request_schema sends and receives schema for known table" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, client} =
        WebSocketClient.start_link(url: test_url(), code: session.code, caller: self())

      assert_receive {:sync_client, :connected}, 5_000

      WebSocketClient.request_schema(client, "phoenix_kit_staff_skills")

      assert_receive {:sync_client, {:schema, "phoenix_kit_staff_skills", _schema}}, 5_000

      WebSocketClient.disconnect(client)
    end

    test "request_records returns paginated records" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, client} =
        WebSocketClient.start_link(url: test_url(), code: session.code, caller: self())

      assert_receive {:sync_client, :connected}, 5_000

      WebSocketClient.request_records(client, "phoenix_kit_staff_skills", limit: 5)

      assert_receive {:sync_client, {:records, "phoenix_kit_staff_skills", result}}, 5_000
      assert is_list(result.records)

      WebSocketClient.disconnect(client)
    end
  end

  describe "start_link/1 — invalid code" do
    test "rejection from server propagates as a closed/disconnect signal" do
      # SocketPlug returns 403 for invalid codes; the WebSocket upgrade
      # never completes, so WebSockex either fails to start or
      # disconnects shortly after start.
      result =
        WebSocketClient.start_link(url: test_url(), code: "BADCODE1", caller: self())

      case result do
        {:ok, client} ->
          # If start_link succeeded, we should hear a disconnect /
          # error notification because the upgrade was rejected.
          assert_receive {:sync_client, msg}, 5_000

          # The shape varies (:disconnected, :channel_closed, {:error, _})
          # but it's not :connected.
          refute msg == :connected

          WebSocketClient.disconnect(client)

        {:error, _} ->
          # Direct failure from start_link is also acceptable.
          :ok
      end
    end
  end
end
