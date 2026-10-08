defmodule PhoenixKitSync.Integration.PullFiltersReceiverTest do
  use PhoenixKitSync.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # The receiver side of a filtered (precise) pull. The filter travels in
  # the pull-data body; a sender that applied it says "filtered": true. A
  # sender that predates filters ignores them and sends the whole table, so
  # without that mark nothing is imported.

  @table "pfr_items"

  setup do
    repo().query!("CREATE TABLE IF NOT EXISTS #{@table} (id bigint PRIMARY KEY, label text)")

    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url()
      })

    {:ok, connection: connection}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp rows, do: repo().query!("SELECT id FROM #{@table} ORDER BY id").rows

  defp transfer_for(table) do
    repo().one!(
      from(t in Transfer,
        where: t.table_name == ^table and t.direction == "receive",
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end

  defp all_rows, do: for(id <- 1..4, do: %{"id" => id, "label" => "item #{id}"})

  test "a sender that applies the filter: only those rows are imported", %{
    connection: connection
  } do
    StubRemote.put_data(@table, Enum.filter(all_rows(), &(&1["id"] in [2, 4])))
    StubRemote.put_response_extra(@table, %{"filtered" => true})

    assert {:ok, %{imported: 2, errors: 0}} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               ids: [2, 4]
             )

    assert %{"ids" => [2, 4]} = StubRemote.last_pull_body(@table)
    assert rows() == [[2], [4]]
  end

  test "the range goes on the wire as id_start / id_end", %{connection: connection} do
    StubRemote.put_data(@table, [])
    StubRemote.put_response_extra(@table, %{"filtered" => true})

    assert {:ok, _} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               id_range: {3, nil}
             )

    body = StubRemote.last_pull_body(@table)
    assert body["id_start"] == 3
    refute Map.has_key?(body, "id_end")
  end

  test "an older sender that ignores the filter: nothing is imported", %{
    connection: connection
  } do
    # The whole table comes back, with no "filtered" mark.
    StubRemote.put_data(@table, all_rows())

    assert {:error, :sender_ignores_filters} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               ids: [2]
             )

    assert rows() == []
    assert %{status: "failed"} = transfer_for(@table)
  end

  test "an answer marked filtered: false is refused like an unmarked one", %{
    connection: connection
  } do
    StubRemote.put_data(@table, all_rows())
    StubRemote.put_response_extra(@table, %{"filtered" => false})

    assert {:error, :sender_ignores_filters} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               ids: [2]
             )

    assert rows() == []
  end

  test "an empty id list or an open range on both ends is refused before any request", %{
    connection: connection
  } do
    StubRemote.put_data(@table, all_rows())

    for opts <- [[ids: []], [id_range: {nil, nil}]] do
      assert {:error, :invalid_filter} =
               ConnectionNotifier.pull_table_data(
                 connection,
                 @table,
                 [conflict_strategy: "skip"] ++ opts
               )
    end

    assert StubRemote.pull_count(@table) == 0
    assert rows() == []
  end

  test "without a filter an older sender's answer imports as before", %{
    connection: connection
  } do
    StubRemote.put_data(@table, all_rows())

    assert {:ok, %{imported: 4}} =
             ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

    refute Map.has_key?(StubRemote.last_pull_body(@table), "ids")
  end

  test "more ids than a sender accepts are refused before any request", %{
    connection: connection
  } do
    StubRemote.put_data(@table, [])

    assert {:error, :invalid_filter} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               ids: Enum.to_list(1..1001)
             )

    assert StubRemote.pull_count(@table) == 0
  end

  # The test endpoint serves the real ApiController over the same
  # database, so a table exists on both sides.
  defp self_peer do
    PhoenixKitSync.enable_system()

    {:ok, sender, token} =
      Connections.create_connection(%{
        "name" => "Self sender #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://self-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, _} = Connections.approve_connection(sender, PhoenixKitSync.TestActor.uuid())
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    %{
      uuid: sender.uuid,
      site_url: "http://localhost:#{port}",
      auth_token_hash: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    }
  end

  test "new receiver and new sender end to end" do
    # The asked-for rows exist on both sides: the pull reads them through
    # the filter and skips them on import.
    repo().query!("INSERT INTO #{@table} SELECT g, 'item' FROM generate_series(1, 5) g")
    peer = self_peer()

    assert {:ok, %{imported: 0, skipped: 2, errors: 0}} =
             ConnectionNotifier.pull_table_data(peer, @table,
               conflict_strategy: "skip",
               ids: [2, 4]
             )

    assert %{status: "completed", records_transferred: 2} = transfer_for(@table)
  end

  test "the sender's error_code picks the reason; an older 400 is :invalid_filter", %{
    connection: connection
  } do
    repo().query!("CREATE TABLE IF NOT EXISTS pfr_days (day date PRIMARY KEY)")
    repo().query!("CREATE TABLE IF NOT EXISTS pfr_pairs (a int, b int, PRIMARY KEY (a, b))")
    peer = self_peer()

    assert {:error, :filter_needs_single_key} =
             ConnectionNotifier.pull_table_data(peer, "pfr_pairs",
               conflict_strategy: "skip",
               ids: [1]
             )

    assert {:error, :unsupported_key_type} =
             ConnectionNotifier.pull_table_data(peer, "pfr_days",
               conflict_strategy: "skip",
               ids: ["2026-01-01"]
             )

    StubRemote.put_raw(@table, 400, %{"success" => false, "error" => "Invalid filter"})

    assert {:error, :invalid_filter} =
             ConnectionNotifier.pull_table_data(connection, @table,
               conflict_strategy: "skip",
               ids: [1]
             )
  end

  test "a preview takes the pull's filter rules", %{connection: connection} do
    assert {:error, :invalid_filter} =
             ConnectionNotifier.fetch_table_records(connection, @table, ids: [], limit: 10)
  end

  test "a filter the sender cannot apply comes back as :invalid_filter" do
    repo().query!("CREATE TABLE IF NOT EXISTS pfr_uuid_items (uuid uuid PRIMARY KEY)")

    assert {:error, :invalid_filter} =
             ConnectionNotifier.pull_table_data(self_peer(), "pfr_uuid_items",
               conflict_strategy: "skip",
               id_range: {1, 5}
             )

    assert %{status: "failed"} = transfer_for("pfr_uuid_items")
  end
end
