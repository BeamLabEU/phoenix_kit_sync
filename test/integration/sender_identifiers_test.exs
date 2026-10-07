defmodule PhoenixKitSync.Integration.SenderIdentifiersTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # Column names, column types and table names that come from the sender
  # are data, not SQL. A pull or a "create table" must never splice one
  # into a statement unchecked: an invalid name is refused before any SQL
  # runs, and the refusal is visible as an error.

  @target "ident_target"
  @victim "ident_victim"
  @injection ~s[a"; DROP TABLE ident_victim; --]

  setup do
    repo().query!("CREATE TABLE IF NOT EXISTS #{@target} (code text PRIMARY KEY, note text)")
    repo().query!("CREATE TABLE IF NOT EXISTS #{@victim} (id int PRIMARY KEY)")
    repo().query!("INSERT INTO #{@victim} VALUES (1) ON CONFLICT DO NOTHING")

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

  defp victim_intact? do
    SchemaInspector.table_exists?(@victim) and
      repo().query!("SELECT count(*)::int FROM #{@victim}").rows == [[1]]
  end

  defp target_rows do
    repo().query!("SELECT code, note FROM #{@target} ORDER BY code").rows
  end

  defp flush_mailbox(acc \\ []) do
    receive do
      msg -> flush_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp transfer_for(table) do
    import Ecto.Query

    repo().one!(
      from(t in Transfer,
        where: t.table_name == ^table,
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end

  defp create(columns, primary_key \\ ["id"]) do
    SchemaInspector.create_table("ident_created", %{
      "columns" => columns,
      "primary_key" => primary_key
    })
  end

  defp col(name, type, pk \\ false),
    do: %{"name" => name, "type" => type, "nullable" => true, "primary_key" => pk}

  describe "a record key that is not a valid identifier" do
    test "rejects the whole table on the remap pull, before any insert", %{
      connection: connection
    } do
      StubRemote.put_data(@target, [
        %{"code" => "ok", "note" => "fine"},
        %{"code" => "bad", @injection => "x"}
      ])

      assert {:error, :invalid_column_name, %{}} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @target, %{},
                 conflict_strategy: "skip"
               )

      assert victim_intact?()
      assert target_rows() == []

      assert %{status: "failed", error_message: message} = transfer_for(@target)
      refute message =~ "DROP"
    end

    test "rejects the whole table on the pull without remap", %{connection: connection} do
      StubRemote.put_data(@target, [%{"code" => "bad", @injection => "x"}])

      assert {:error, :invalid_column_name} =
               ConnectionNotifier.pull_table_data(connection, @target, conflict_strategy: "skip")

      assert victim_intact?()
      assert target_rows() == []
    end
  end

  describe "a record key that names no local column" do
    test "fails that record without sending it to the database", %{connection: connection} do
      StubRemote.put_data(@target, [
        %{"code" => "a", "note" => "fine"},
        %{"code" => "b", "extra" => "not here"}
      ])

      handler = "ident-sql-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:phoenix_kit_sync, :test, :repo, :query],
        fn _event, _measurements, meta, _ -> send(test_pid, {:sql, meta.query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{imported: 1, skipped: 0, errors: 1}, %{}} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @target, %{},
                 conflict_strategy: "skip"
               )

      assert target_rows() == [["a", "fine"]]

      # The unknown name never reached the database.
      queries = for {:sql, query} <- flush_mailbox(), do: query
      assert Enum.any?(queries, &(&1 =~ "INSERT INTO"))
      refute Enum.any?(queries, &(&1 =~ ~s["extra"]))
    end
  end

  describe "a table name that is not a valid identifier" do
    test "is refused before anything is requested", %{connection: connection} do
      table = ~s[x"; DROP TABLE ident_victim; --]
      StubRemote.put_data(table, [%{"code" => "a"}])

      assert {:error, :invalid_table_name, %{}} =
               ConnectionNotifier.pull_table_data_with_remap(connection, table, %{},
                 conflict_strategy: "skip"
               )

      assert StubRemote.pull_count(table) == 0
      assert victim_intact?()
    end
  end

  describe "create_table/2 with a sender's schema" do
    test "refuses a column name that is not a valid identifier" do
      assert {:error, :invalid_identifier} =
               create([col("id", "bigint", true), col(@injection, "text")])

      assert victim_intact?()
      refute SchemaInspector.table_exists?("ident_created")
    end

    test "refuses a column type that is not a plain type name" do
      assert {:error, :invalid_column_type} =
               create([
                 col("id", "bigint", true),
                 col("note", "text); DROP TABLE ident_victim; --")
               ])

      assert {:error, :invalid_column_type} =
               create([col("id", "bigint", true), col("note", "text REFERENCES ident_victim")])

      # Plain words, but not a type name: each would append a clause.
      for type <- ["integer UNIQUE", "text NOT NULL", "integer REFERENCES victim"] do
        assert {:error, :invalid_column_type} =
                 create([col("id", "bigint", true), col("note", type)])
      end

      assert victim_intact?()
      refute SchemaInspector.table_exists?("ident_created")
    end

    test "refuses a primary key column that is not a valid identifier" do
      assert {:error, :invalid_identifier} =
               create([col("id", "bigint", true)], ["id); DROP TABLE ident_victim; --"])

      assert victim_intact?()
      refute SchemaInspector.table_exists?("ident_created")
    end

    test "still accepts the types information_schema reports" do
      assert :ok =
               create([
                 col("id", "bigint", true),
                 col("title", "character varying"),
                 col("code", "character varying(20)"),
                 col("price", "numeric(10,2)"),
                 col("at", "timestamp with time zone"),
                 col("seen", "time without time zone"),
                 col("ratio", "double precision"),
                 col("tags", "text[]"),
                 col("ref", "uuid"),
                 col("data", "jsonb")
               ])

      assert SchemaInspector.table_exists?("ident_created")
    end
  end
end
