defmodule PhoenixKitSync.Integration.TransferLimitsTest do
  use PhoenixKitSync.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SyncableTable
  alias PhoenixKitSync.Test.Repo, as: TestRepo
  alias PhoenixKitSync.Web.SyncWebsock

  # `max_downloads` and `max_records_total` are what a connection may take
  # in all. These tests read a table through every action that serves rows
  # and pin that neither limit is passed: one request after another, two
  # at once, and page by page.

  @table SyncableTable.name()

  setup do
    PhoenixKitSync.enable_system()
    :ok
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp create(attrs) do
    {:ok, connection, token} =
      Connections.create_connection(
        Map.merge(
          %{
            "name" => "Peer #{System.unique_integer([:positive])}",
            "direction" => "sender",
            "site_url" => "https://limits-#{System.unique_integer([:positive])}.example.com",
            "status" => "active"
          },
          attrs
        )
      )

    {connection, token}
  end

  defp rows(count), do: for(_ <- 1..count, do: SyncableTable.insert!())

  defp rest(action, token, extra \\ %{}) do
    post(
      build_conn(),
      "/sync/api/#{action}",
      Map.merge(%{"auth_token_hash" => token_hash(token), "table_name" => @table}, extra)
    )
  end

  defp counted(connection), do: Connections.get_connection!(connection.uuid)

  # ===========================================
  # table-records
  # ===========================================

  describe "table-records" do
    test "counts a download and its rows" do
      rows(3)
      {connection, token} = create(%{})

      assert %{"records" => [_, _]} =
               json_response(rest("table-records", token, %{"limit" => 2}), 200)

      assert %{downloads_used: 1, records_downloaded: 2, total_records_transferred: 2} =
               counted(connection)
    end

    test "pages with successive offsets stop at max_downloads" do
      rows(4)
      {connection, token} = create(%{"max_downloads" => 2})

      statuses =
        for offset <- 0..3 do
          rest("table-records", token, %{"limit" => 1, "offset" => offset}).status
        end

      assert statuses == [200, 200, 403, 403]
      assert counted(connection).downloads_used == 2
    end

    test "pages with successive offsets stop at max_records_total" do
      rows(6)
      {connection, token} = create(%{"max_records_total" => 3})

      served =
        for offset <- [0, 2, 4] do
          response = rest("table-records", token, %{"limit" => 2, "offset" => offset})
          if response.status == 200, do: length(json_response(response, 200)["records"]), else: 0
        end

      # Two rows, then the one row left of the limit, then nothing.
      assert served == [2, 1, 0]
      assert counted(connection).records_downloaded == 3
    end

    test "a refused request takes nothing from the limits" do
      rows(1)
      {connection, token} = create(%{"max_downloads" => 5})

      assert json_response(rest("table-records", token, %{"table_name" => "no_such_table"}), 404)

      assert %{downloads_used: 0, records_downloaded: 0} = counted(connection)
    end
  end

  # ===========================================
  # pull-data
  # ===========================================

  describe "pull-data" do
    test "a pull that fails gives its download back" do
      {connection, token} = create(%{"max_downloads" => 1})

      assert json_response(rest("pull-data", token, %{"table_name" => "no_such_table"}), 404)
      assert counted(connection).downloads_used == 0

      assert json_response(rest("pull-data", token), 200)
      assert counted(connection).downloads_used == 1
    end

    test "the answer is cut to what is left of max_records_total" do
      rows(5)
      {connection, token} = create(%{"max_records_total" => 3})

      body = json_response(rest("pull-data", token), 200)
      assert length(body["data"]) == 3
      assert body["has_more"] == true

      assert rest("pull-data", token).status == 403
      assert counted(connection).records_downloaded == 3
    end
  end

  # ===========================================
  # The reservation
  # ===========================================

  describe "reserve_transfer/2" do
    test "grants what is left of the record limit and refuses once it is used" do
      {connection, _token} = create(%{"max_records_total" => 10})

      assert {:ok, first} = Connections.reserve_transfer(connection, %{downloads: 1, records: 7})
      assert first.records == 7
      assert {:ok, _} = Connections.settle_transfer(first, 7)

      assert {:ok, second} = Connections.reserve_transfer(connection, %{downloads: 1, records: 7})
      assert second.records == 3
      assert {:ok, _} = Connections.settle_transfer(second, 3)

      assert {:error, :record_limit_reached} =
               Connections.reserve_transfer(connection, %{downloads: 1, records: 7})

      assert %{records_downloaded: 10, downloads_used: 2} = counted(connection)
    end

    test "a reservation in flight holds its whole page; settling gives the rest back" do
      {connection, _token} = create(%{"max_records_total" => 10})

      assert {:ok, held} = Connections.reserve_transfer(connection, %{downloads: 1, records: 10})

      assert {:error, :record_limit_reached} =
               Connections.reserve_transfer(connection, %{downloads: 1, records: 1})

      assert {:ok, _} = Connections.settle_transfer(held, 4)
      assert counted(connection).records_downloaded == 4

      assert {:ok, %{records: 6}} =
               Connections.reserve_transfer(connection, %{downloads: 1, records: 10})
    end

    test "names the limit that refused" do
      {downloads, _} = create(%{"max_downloads" => 1})
      assert {:ok, _} = Connections.reserve_transfer(downloads, %{downloads: 1, records: 1})

      assert {:error, :download_limit_reached} =
               Connections.reserve_transfer(downloads, %{downloads: 1, records: 1})

      # A further page of a download already counted is not held to it.
      assert {:ok, _} = Connections.reserve_transfer(downloads, %{downloads: 0, records: 1})
    end

    test "cancel gives the download and the page back" do
      {connection, _token} = create(%{"max_downloads" => 1, "max_records_total" => 5})

      assert {:ok, reservation} =
               Connections.reserve_transfer(connection, %{downloads: 1, records: 5})

      assert {:ok, _} = Connections.cancel_transfer(reservation)
      assert %{downloads_used: 0, records_downloaded: 0} = counted(connection)
    end

    test "a connection without a record limit counts what was served" do
      {connection, _token} = create(%{})

      assert {:ok, reservation} =
               Connections.reserve_transfer(connection, %{downloads: 1, records: 100})

      assert counted(connection).records_downloaded == 0
      assert {:ok, _} = Connections.settle_transfer(reservation, 40)
      assert counted(connection).records_downloaded == 40
    end
  end

  describe "requests arriving together" do
    # A race needs connections that do not share a transaction, so these
    # run outside the sandbox and remove what they wrote.
    @marker "limits-race-#{System.unique_integer([:positive])}"

    setup do
      on_exit(fn ->
        Sandbox.unboxed_run(TestRepo, fn ->
          TestRepo.query!(
            "DELETE FROM phoenix_kit_activities WHERE resource_uuid IN " <>
              "(SELECT uuid FROM phoenix_kit_sync_connections WHERE site_url ILIKE $1)",
            ["%#{@marker}%"]
          )

          TestRepo.query!("DELETE FROM phoenix_kit_sync_connections WHERE site_url ILIKE $1", [
            "%#{@marker}%"
          ])
        end)
      end)

      :ok
    end

    defp committed_connection(attrs) do
      Sandbox.unboxed_run(TestRepo, fn ->
        {connection, _token} =
          create(
            Map.put(
              attrs,
              "site_url",
              "https://#{@marker}-#{System.unique_integer([:positive])}.example.com"
            )
          )

        connection
      end)
    end

    defp race(connection, count, attrs) do
      1..count
      |> Enum.map(fn _ -> Task.async(fn -> reserve_unboxed(connection, attrs) end) end)
      |> Task.await_many(30_000)
    end

    defp reserve_unboxed(connection, attrs) do
      Sandbox.unboxed_run(TestRepo, fn -> Connections.reserve_transfer(connection, attrs) end)
    end

    defp committed(connection) do
      Sandbox.unboxed_run(TestRepo, fn -> Connections.get_connection!(connection.uuid) end)
    end

    test "twenty at once for the last download: one is granted" do
      connection = committed_connection(%{"max_downloads" => 1})

      results = race(connection, 20, %{downloads: 1, records: 1})

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :download_limit_reached})) == 19
      assert committed(connection).downloads_used == 1
    end

    test "twenty at once for ten records: no more than ten are granted" do
      connection = committed_connection(%{"max_records_total" => 10})

      results = race(connection, 20, %{downloads: 1, records: 4})
      granted = for {:ok, reservation} <- results, do: reservation

      assert granted |> Enum.map(& &1.records) |> Enum.sum() == 10

      Sandbox.unboxed_run(TestRepo, fn ->
        Enum.each(granted, &Connections.settle_transfer(&1, &1.records))
      end)

      assert committed(connection).records_downloaded == 10
    end
  end

  # ===========================================
  # The WebSocket
  # ===========================================

  describe "pages on one socket" do
    defp open(connection) do
      {:ok, state} = SyncWebsock.init(auth_type: :connection, connection: connection)
      %{state | joined: true}
    end

    defp request(state, connection, payload) do
      frame =
        Jason.encode!([
          nil,
          "1",
          "transfer:conn:#{connection.uuid}",
          "request:records",
          Map.merge(%{"table" => @table, "ref" => "r"}, payload)
        ])

      {:push, {:text, reply}, state} = SyncWebsock.handle_in({frame, [opcode: :text]}, state)
      [_join_ref, _ref, _topic, event, response] = Jason.decode!(reply)
      {event, response, state}
    end

    test "a table read by position is one download, and every row counts" do
      rows(5)
      {connection, _token} = create(%{"max_downloads" => 1})
      state = open(connection)

      {"response:records", first, state} = request(state, connection, %{"limit" => 2})
      assert length(first["records"]) == 2

      {"response:records", second, state} =
        request(state, connection, %{"limit" => 2, "offset" => 2, "after" => first["next_after"]})

      assert length(second["records"]) == 2

      {"response:records", third, state} =
        request(state, connection, %{"limit" => 2, "offset" => 4, "after" => second["next_after"]})

      assert length(third["records"]) == 1

      # The receiver reads on until an empty page: that one is free as well.
      {"response:records", last, _state} =
        request(state, connection, %{"limit" => 2, "offset" => 5, "after" => third["next_after"]})

      assert last["records"] == []

      assert %{downloads_used: 1, records_downloaded: 5} = counted(connection)
    end

    test "a table read by offset is one download" do
      rows(3)
      {connection, _token} = create(%{"max_downloads" => 1})
      state = open(connection)

      {"response:records", _, state} = request(state, connection, %{"limit" => 2})

      {"response:records", second, _state} =
        request(state, connection, %{"limit" => 2, "offset" => 2})

      assert length(second["records"]) == 1
      assert %{downloads_used: 1, records_downloaded: 3} = counted(connection)
    end

    test "a position the socket did not answer is a new download" do
      [first_row | _] = Enum.sort(rows(3))
      {connection, _token} = create(%{"max_downloads" => 1})
      state = open(connection)

      {"response:records", first, state} = request(state, connection, %{"limit" => 2})
      refute first["next_after"] == %{"uuid" => first_row}

      # The peer names a position of its own choosing.
      {"response:error", refused, state} =
        request(state, connection, %{"limit" => 2, "after" => %{"uuid" => first_row}})

      assert refused["error"] =~ "download_limit_reached"

      # An offset it was not given either.
      {"response:error", _refused, _state} =
        request(state, connection, %{"limit" => 2, "offset" => 1})

      assert counted(connection).downloads_used == 1
    end

    test "another socket does not continue this one's download" do
      rows(3)
      {connection, _token} = create(%{"max_downloads" => 1})

      {"response:records", first, _state} = request(open(connection), connection, %{"limit" => 2})

      {"response:error", refused, _state} =
        request(open(connection), connection, %{
          "limit" => 2,
          "offset" => 2,
          "after" => first["next_after"]
        })

      assert refused["error"] =~ "download_limit_reached"
    end

    test "the pages of one read stop at max_records_total" do
      rows(5)
      {connection, _token} = create(%{"max_records_total" => 3})
      state = open(connection)

      {"response:records", first, state} = request(state, connection, %{"limit" => 2})
      assert length(first["records"]) == 2

      {"response:records", second, state} =
        request(state, connection, %{"limit" => 2, "offset" => 2, "after" => first["next_after"]})

      assert length(second["records"]) == 1

      {"response:error", refused, _state} =
        request(state, connection, %{"limit" => 2, "offset" => 3, "after" => second["next_after"]})

      assert refused["error"] =~ "record_limit_reached"
      assert counted(connection).records_downloaded == 3
    end
  end
end
