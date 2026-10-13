defmodule PhoenixKitSync.Integration.PullTruncatedReceiverTest do
  use PhoenixKitSync.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # A sender that cut its answer at max_records_per_request says
  # "truncated": true. The rows that came are imported, but the pull is not
  # a completed one: the transfer fails with the reason, and the result
  # carries the mark so the UI shows it.

  @table "ptr_items"

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

    StubRemote.put_data(@table, for(id <- 1..3, do: %{"id" => id, "label" => "item #{id}"}))

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

  test "a truncated answer is imported, but the transfer fails as truncated", %{
    connection: connection
  } do
    StubRemote.put_response_extra(@table, %{"truncated" => true})

    assert {:ok, %{imported: 3, truncated: true}} =
             ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

    assert rows() == [[1], [2], [3]]

    transfer = transfer_for(@table)
    assert transfer.status == "failed"
    assert transfer.error_message == "truncated"
    assert transfer.records_transferred == 3
    assert transfer.records_created == 3
  end

  describe "a sender that names the key type it has no cursor for" do
    test "the result and the transfer name it", %{connection: connection} do
      StubRemote.put_response_extra(@table, %{
        "truncated" => true,
        "unsupported_key_type" => "time with time zone"
      })

      assert {:ok, %{imported: 3, truncated: true, unsupported_key_type: "time with time zone"}} =
               ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

      transfer = transfer_for(@table)
      assert transfer.status == "failed"
      assert transfer.error_message == "truncated_key_type:time with time zone"
      # Updating the sender would not help; that advice is left out.
      refute transfer.error_message =~ "Update the sync module"
    end

    # The name is the peer's text and is shown to the admin: anything but a
    # short printable string is dropped, and the pull reads as plainly cut.
    @bad_names [
      {"a number", 5},
      {"a map", %{"type" => "interval"}},
      {"a list", ["interval"]},
      {"an empty string", ""},
      {"too long", String.duplicate("x", 201)},
      {"control characters", "interval\u0000\u0007"}
    ]

    for {label, name} <- @bad_names do
      test "#{label} for a name is not kept", %{connection: connection} do
        StubRemote.put_response_extra(@table, %{
          "truncated" => true,
          "unsupported_key_type" => unquote(Macro.escape(name))
        })

        assert {:ok, %{truncated: true} = result} =
                 ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

        refute Map.has_key?(result, :unsupported_key_type)
        assert transfer_for(@table).error_message == "truncated"
      end
    end

    test "a name on an answer that was not cut changes nothing", %{connection: connection} do
      StubRemote.put_response_extra(@table, %{"unsupported_key_type" => "interval"})

      assert {:ok, result} =
               ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

      refute Map.has_key?(result, :truncated)
      refute Map.has_key?(result, :unsupported_key_type)
      assert transfer_for(@table).status == "completed"
    end
  end

  test "the remap pull marks a truncated answer the same way", %{connection: connection} do
    StubRemote.put_response_extra(@table, %{"truncated" => true})

    assert {:ok, %{imported: 3, truncated: true}, _remap} =
             ConnectionNotifier.pull_table_data_with_remap(connection, @table, %{},
               conflict_strategy: "skip"
             )

    assert transfer_for(@table).status == "failed"
  end

  test "an answer without the mark completes as before", %{connection: connection} do
    # A sender from before the mark cannot say it cut the table.
    assert {:ok, result} =
             ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "skip")

    refute Map.has_key?(result, :truncated)
    assert transfer_for(@table).status == "completed"
  end
end
