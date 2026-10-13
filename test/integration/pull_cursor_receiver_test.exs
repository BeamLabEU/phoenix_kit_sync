defmodule PhoenixKitSync.Integration.PullCursorReceiverTest do
  use PhoenixKitSync.DataCase, async: false

  import Ecto.Query
  import PhoenixKitSync.ActivityLogAssertions

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # The receiving side of a bulk pull: it follows the sender's cursor to the
  # end of the table, and stops cleanly at a sender that has none or that
  # does not honour it.

  @table "pcr_items"

  setup do
    repo().query!("CREATE TABLE #{@table} (id bigint PRIMARY KEY, label text)")

    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url(),
        "status" => "active"
      })

    StubRemote.put_data(@table, for(id <- 1..8, do: %{"id" => id, "label" => "item #{id}"}))

    {:ok, connection: connection}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp ids, do: repo().query!("SELECT id FROM #{@table} ORDER BY id").rows |> List.flatten()

  defp transfer do
    repo().one!(
      from(t in Transfer,
        where: t.table_name == @table and t.direction == "receive",
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end

  defp pull(connection, :plain, opts),
    do: ConnectionNotifier.pull_table_data(connection, @table, opts)

  defp pull(connection, :remap, opts) do
    case ConnectionNotifier.pull_table_data_with_remap(connection, @table, %{}, opts) do
      {:ok, result, _remap} -> {:ok, result}
      {:error, reason, _remap} -> {:error, reason}
    end
  end

  for path <- [:plain, :remap] do
    describe "#{path} pull from a sender that pages" do
      test "follows the cursor to the end of the table", %{connection: connection} do
        StubRemote.put_page_size(@table, 3)

        assert {:ok, result} = pull(connection, unquote(path), conflict_strategy: "skip")

        assert result.imported == 8
        refute Map.has_key?(result, :truncated)
        assert ids() == Enum.to_list(1..8)

        # Three pages: each request after the first carries the position and
        # the cursor the answer before it gave.
        assert [first, second, third] = StubRemote.pull_bodies(@table)
        assert first["paged"] == true
        refute Map.has_key?(first, "after")
        assert %{"after" => %{"id" => "3"}, "cursor" => "stub-cursor"} = second
        assert %{"after" => %{"id" => "6"}, "cursor" => "stub-cursor"} = third

        assert %{status: "completed", records_transferred: 8, records_created: 8} = transfer()
      end

      test "counts skipped and failed rows across pages", %{connection: connection} do
        repo().query!("INSERT INTO #{@table} VALUES (2, 'here'), (7, 'here')")
        StubRemote.put_page_size(@table, 3)

        assert {:ok, %{imported: 6, skipped: 2}} =
                 pull(connection, unquote(path), conflict_strategy: "skip")

        assert %{records_transferred: 8, records_created: 6, records_skipped: 2} = transfer()
      end

      test "a sender with no cursor is pulled once and reported cut, as before", %{
        connection: connection
      } do
        StubRemote.put_data(@table, for(id <- 1..3, do: %{"id" => id, "label" => "item #{id}"}))
        StubRemote.put_response_extra(@table, %{"truncated" => true})

        assert {:ok, %{imported: 3, truncated: true}} =
                 pull(connection, unquote(path), conflict_strategy: "skip")

        assert StubRemote.pull_count(@table) == 1
        assert %{status: "failed", records_transferred: 3} = transfer()
      end

      test "a sender that hands out a cursor and then ignores it is stopped at the repeat", %{
        connection: connection
      } do
        StubRemote.put_data(@table, for(id <- 1..3, do: %{"id" => id, "label" => "item #{id}"}))

        StubRemote.put_response_extra(@table, %{
          "truncated" => true,
          "next_after" => %{"id" => "3"},
          "cursor" => "c"
        })

        assert {:ok, %{imported: 3, skipped: 0, truncated: true}} =
                 pull(connection, unquote(path), conflict_strategy: "skip")

        # The same page came back for the second request; it was not
        # imported again and no third request was made.
        assert StubRemote.pull_count(@table) == 2
        assert ids() == [1, 2, 3]
        assert %{status: "failed", records_transferred: 3} = transfer()
      end

      test "a cursor that does not move ends the pull", %{connection: connection} do
        StubRemote.put_data(@table, [])

        StubRemote.put_response_extra(@table, %{
          "truncated" => true,
          "next_after" => %{"id" => "3"}
        })

        assert {:ok, %{imported: 0, truncated: true}} =
                 pull(connection, unquote(path), conflict_strategy: "skip")

        assert StubRemote.pull_count(@table) == 2
      end

      test "the pull is recorded with who started it and when", %{connection: connection} do
        actor = PhoenixKitSync.TestActor.uuid()

        assert {:ok, _} =
                 pull(connection, unquote(path), conflict_strategy: "skip", actor_uuid: actor)

        transfer = transfer()
        assert transfer.initiated_by_uuid == actor
        assert %DateTime{} = transfer.started_at
        assert DateTime.compare(transfer.started_at, transfer.completed_at) in [:lt, :eq]

        assert_activity_logged("sync.transfer.created",
          resource_uuid: transfer.uuid,
          actor_uuid: actor
        )
      end
    end
  end

  describe "what the sender refuses a pull with" do
    @refusals [
      {403, "connection_not_active", :connection_not_active},
      {403, "connection_expired", :connection_expired},
      {403, "download_limit_reached", :download_limit_reached},
      {403, "record_limit_reached", :record_limit_reached},
      {403, "ip_not_allowed", :ip_not_allowed},
      {403, "outside_allowed_hours", :outside_allowed_hours},
      {403, "invalid_password", :invalid_password},
      {400, "no_primary_key", :source_without_primary_key},
      {400, "invalid_cursor", :invalid_cursor},
      {403, "something_new", :unexpected_response},
      {403, nil, :unexpected_response}
    ]

    for {status, code, reason} <- @refusals do
      test "#{status} #{inspect(code)} is #{inspect(reason)}", %{connection: connection} do
        StubRemote.put_raw(@table, unquote(status), %{
          "success" => false,
          "error" => "refused",
          "error_code" => unquote(code)
        })

        assert {:error, unquote(reason)} = ConnectionNotifier.pull_table_data(connection, @table)
        assert transfer().status == "failed"
        assert is_binary(PhoenixKitSync.Errors.message(unquote(reason)))
        # A sentence for the admin, not the atom printed.
        refute PhoenixKitSync.Errors.message(unquote(reason)) == inspect(unquote(reason))
      end
    end
  end

  describe "the download password" do
    test "goes with every page when the caller has one", %{connection: connection} do
      StubRemote.put_page_size(@table, 5)

      assert {:ok, _} = ConnectionNotifier.pull_table_data(connection, @table, password: "s3cret")

      assert [%{"password" => "s3cret"}, %{"password" => "s3cret"}] =
               StubRemote.pull_bodies(@table)
    end

    test "is not sent when there is none", %{connection: connection} do
      assert {:ok, _} = ConnectionNotifier.pull_table_data(connection, @table)
      assert [body] = StubRemote.pull_bodies(@table)
      refute Map.has_key?(body, "password")
    end
  end
end
