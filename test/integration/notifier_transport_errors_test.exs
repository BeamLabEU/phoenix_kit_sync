defmodule PhoenixKitSync.Integration.NotifierTransportErrorsTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier

  # What a failed request to the remote site is recorded as. Finch reports
  # a transport failure and a protocol failure as its own exception structs;
  # each is turned into a short text, never printed whole.

  # A listener that answers every connection with `reply` and closes.
  defp listener(reply) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn -> :gen_tcp.accept(socket, 2_000) end)
        |> Enum.find(fn
          {:ok, client} ->
            _ = :gen_tcp.recv(client, 0, 1_000)
            :gen_tcp.send(client, reply)
            :gen_tcp.close(client)
            false

          {:error, _} ->
            true
        end)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(socket)
    end)

    port
  end

  defp notify(port) do
    ConnectionNotifier.notify_remote_site(
      %{site_url: "http://localhost:#{port}", name: "Probe", direction: "sender"},
      "token",
      timeout: 2_000
    )
  end

  test "a refused connection is a transport error, named by its reason" do
    # Bound and released: nothing listens on it now.
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    assert {:ok, %{success: false, status: :failed, http_status: nil, error: error}} =
             notify(port)

    assert error == "Connection failed: :econnrefused"
  end

  test "an answer that is not HTTP is an HTTP error, named by its reason" do
    port = listener("this is not http\r\n\r\n")

    assert {:ok, %{success: false, status: :failed, error: error}} = notify(port)
    assert "HTTP error: " <> reason = error
    refute reason =~ "%"
    refute error =~ "Finch"
  end

  test "a peer sending chunks continually cannot keep a request open indefinitely" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(socket, 2_000)
        :gen_tcp.recv(client, 0, 1_000)
        :gen_tcp.send(client, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")

        for _ <- 1..60 do
          Process.sleep(50)
          :gen_tcp.send(client, " ")
        end

        :gen_tcp.close(client)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(socket)
    end)

    connection = %{site_url: "http://localhost:#{port}", auth_token_hash: "hash"}

    assert {:error, :offline} =
             ConnectionNotifier.fetch_table_schema(connection, "rows", timeout: 200)
  end

  test "the same failures on a pull are classified, and the transfer is closed" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    PhoenixKit.RepoHelper.repo().query!("CREATE TABLE nte_rows (id bigint PRIMARY KEY)")
    connection = %{site_url: "http://localhost:#{port}", auth_token_hash: "h"}

    assert {:error, :offline} = ConnectionNotifier.pull_table_data(connection, "nte_rows")
    assert {:ok, :offline} = ConnectionNotifier.verify_connection(connection)
    assert {:ok, :offline} = ConnectionNotifier.notify_delete(connection)
    assert {:error, :offline} = ConnectionNotifier.fetch_sender_tables(connection)

    assert %{rows: [["failed", "offline"]]} =
             PhoenixKit.RepoHelper.repo().query!(
               "SELECT status, error_message FROM phoenix_kit_sync_transfers WHERE table_name = 'nte_rows'"
             )
  end
end
