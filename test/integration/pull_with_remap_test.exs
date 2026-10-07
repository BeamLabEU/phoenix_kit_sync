defmodule PhoenixKitSync.Integration.PullWithRemapTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote
  alias PhoenixKitSync.Transfer

  # Receiver-side pull through `pull_table_data_with_remap/4`, the path the
  # Connections "Sync data" page drives table by table. The sender is
  # `StubRemote`, so the rows it serves are not already in the local DB.
  #
  # `cpk_parents` has a single text PK and a unique `name`, so a sender row
  # whose name exists locally is matched and remapped. `cpk_slugs` has a
  # composite PK `(lang, value)` and an FK to `cpk_parents`.
  # `cpk_owner_slugs` is the shape of `phoenix_kit_cat_category_slugs`:
  # composite PK plus a uuid FK, which the sender puts on the wire as a
  # base64-wrapped 16-byte binary.

  @parents "cpk_parents"
  @slugs "cpk_slugs"
  @owners "cpk_owners"
  @owner_slugs "cpk_owner_slugs"

  setup do
    repo().query!("""
    CREATE TABLE IF NOT EXISTS #{@parents} (
      code text PRIMARY KEY,
      name text NOT NULL UNIQUE
    )
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS #{@slugs} (
      lang text NOT NULL,
      value text NOT NULL,
      parent_code text REFERENCES #{@parents}(code),
      note text,
      PRIMARY KEY (lang, value)
    )
    """)

    repo().query!("CREATE TABLE IF NOT EXISTS #{@owners} (uuid uuid PRIMARY KEY)")

    repo().query!("""
    CREATE TABLE IF NOT EXISTS #{@owner_slugs} (
      lang text NOT NULL,
      value text NOT NULL,
      owner_uuid uuid NOT NULL REFERENCES #{@owners}(uuid) ON DELETE CASCADE,
      PRIMARY KEY (lang, value)
    )
    """)

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

  defp insert_parent(code, name) do
    repo().query!("INSERT INTO #{@parents} (code, name) VALUES ($1, $2)", [code, name])
  end

  defp insert_slug(lang, value, parent_code, note) do
    repo().query!(
      "INSERT INTO #{@slugs} (lang, value, parent_code, note) VALUES ($1, $2, $3, $4)",
      [lang, value, parent_code, note]
    )
  end

  defp slugs do
    %{rows: rows} =
      repo().query!("SELECT lang, value, parent_code, note FROM #{@slugs} ORDER BY lang, value")

    rows
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

  defp slug(lang, value, parent_code, note) do
    %{"lang" => lang, "value" => value, "parent_code" => parent_code, "note" => note}
  end

  # How ApiController serialises a uuid column (a non-UTF-8 binary).
  defp wire_uuid(uuid), do: %{"__phoenix_kit_binary__" => Base.encode64(Ecto.UUID.dump!(uuid))}

  describe "composite primary key" do
    test "imports the rows, remapping FK columns through the uuid_remap", %{
      connection: connection
    } do
      insert_parent("local-shelves", "shelves")

      StubRemote.put_data(@slugs, [
        slug("en", "shelves", "remote-shelves", "a"),
        slug("et", "riiulid", "remote-shelves", "b")
      ])

      remap = %{{@parents, "remote-shelves"} => "local-shelves"}

      assert {:ok, result, ^remap} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @slugs, remap,
                 conflict_strategy: "skip"
               )

      assert %{imported: 2, skipped: 0, errors: 0} = result

      assert slugs() == [
               ["en", "shelves", "local-shelves", "a"],
               ["et", "riiulid", "local-shelves", "b"]
             ]

      assert %{status: "completed", records_created: 2} = transfer_for(@slugs)
    end

    test "imports the category_slugs shape: composite key plus a uuid FK on the wire", %{
      connection: connection
    } do
      owner = UUIDv7.generate()
      repo().query!("INSERT INTO #{@owners} (uuid) VALUES ($1)", [Ecto.UUID.dump!(owner)])

      StubRemote.put_data(@owner_slugs, [
        %{"lang" => "en", "value" => "shelves", "owner_uuid" => wire_uuid(owner)},
        %{"lang" => "et", "value" => "riiulid", "owner_uuid" => wire_uuid(owner)}
      ])

      assert {:ok, %{imported: 2, skipped: 0, errors: 0}, %{}} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @owner_slugs, %{},
                 conflict_strategy: "skip"
               )

      %{rows: rows} =
        repo().query!(
          "SELECT lang, value, owner_uuid::text FROM #{@owner_slugs} ORDER BY lang, value"
        )

      assert rows == [["en", "shelves", owner], ["et", "riiulid", owner]]
    end

    test "skip leaves an existing row with the same composite key untouched", %{
      connection: connection
    } do
      insert_parent("p1", "shelves")
      insert_slug("en", "shelves", "p1", "local")

      StubRemote.put_data(@slugs, [
        slug("en", "shelves", "p1", "remote"),
        slug("en", "hooks", "p1", "new")
      ])

      assert {:ok, %{imported: 1, skipped: 1, errors: 0}, _} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @slugs, %{},
                 conflict_strategy: "skip"
               )

      assert slugs() == [
               ["en", "hooks", "p1", "new"],
               ["en", "shelves", "p1", "local"]
             ]
    end

    test "overwrite updates the row matched on the whole composite key", %{
      connection: connection
    } do
      insert_parent("p1", "shelves")
      insert_slug("en", "shelves", "p1", "local")
      insert_slug("et", "shelves", "p1", "other language")

      StubRemote.put_data(@slugs, [slug("en", "shelves", "p1", "remote")])

      assert {:ok, %{imported: 1, skipped: 0, errors: 0}, _} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @slugs, %{},
                 conflict_strategy: "overwrite"
               )

      assert slugs() == [
               ["en", "shelves", "p1", "remote"],
               ["et", "shelves", "p1", "other language"]
             ]
    end

    test "append keeps the key columns and skips a row whose key is taken", %{
      connection: connection
    } do
      insert_parent("p1", "shelves")
      insert_slug("en", "shelves", "p1", "local")

      StubRemote.put_data(@slugs, [
        slug("en", "shelves", "p1", "remote"),
        slug("en", "hooks", "p1", "new")
      ])

      assert {:ok, %{imported: 1, skipped: 1, errors: 0}, _} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @slugs, %{},
                 conflict_strategy: "append"
               )

      assert slugs() == [
               ["en", "hooks", "p1", "new"],
               ["en", "shelves", "p1", "local"]
             ]
    end

    test "the pull without remap imports composite-key rows too", %{connection: connection} do
      insert_parent("p1", "shelves")
      insert_slug("en", "shelves", "p1", "local")

      StubRemote.put_data(@slugs, [slug("en", "shelves", "p1", "remote")])

      assert {:ok, %{imported: 1, skipped: 0, errors: 0}} =
               ConnectionNotifier.pull_table_data(connection, @slugs,
                 conflict_strategy: "overwrite"
               )

      assert slugs() == [["en", "shelves", "p1", "remote"]]
    end
  end

  describe "single-column primary key (regression)" do
    test "matches by unique column, records the remap and imports new rows", %{
      connection: connection
    } do
      insert_parent("local-shelves", "shelves")

      StubRemote.put_data(@parents, [
        %{"code" => "remote-shelves", "name" => "shelves"},
        %{"code" => "remote-hooks", "name" => "hooks"}
      ])

      assert {:ok, %{imported: 1, skipped: 1, errors: 0}, remap} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @parents, %{},
                 conflict_strategy: "skip"
               )

      assert remap == %{{@parents, "remote-shelves"} => "local-shelves"}

      %{rows: rows} = repo().query!("SELECT code, name FROM #{@parents} ORDER BY name")
      assert rows == [["remote-hooks", "hooks"], ["local-shelves", "shelves"]]
    end

    test "a row whose primary key exists is skipped, as before", %{connection: connection} do
      insert_parent("p1", "shelves")

      StubRemote.put_data(@parents, [%{"code" => "p1", "name" => "renamed"}])

      # The remap path skips a row whose PK exists before trying to insert,
      # whatever the strategy, so the local row stays as it was.
      assert {:ok, %{imported: 0, skipped: 1, errors: 0}, %{}} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @parents, %{},
                 conflict_strategy: "overwrite"
               )

      %{rows: rows} = repo().query!("SELECT code, name FROM #{@parents}")
      assert rows == [["p1", "shelves"]]
    end
  end

  describe "an import that raises" do
    test "fails the transfer and returns an error instead of crashing the caller", %{
      connection: connection
    } do
      # A record that is not a map cannot be read field by field.
      StubRemote.put_data(@parents, ["not a record"])

      remap = %{{"other", "a"} => "b"}

      assert {:error, :import_failed, ^remap} =
               ConnectionNotifier.pull_table_data_with_remap(connection, @parents, remap,
                 conflict_strategy: "skip"
               )

      transfer = transfer_for(@parents)
      assert transfer.status == "failed"
      refute transfer.error_message =~ "not a record"
    end

    test "the pull without remap fails its transfer the same way", %{connection: connection} do
      # `data` that is not a list: counting the records raises.
      StubRemote.put_data(@parents, %{"not" => "a list"})

      assert {:error, :import_failed} =
               ConnectionNotifier.pull_table_data(connection, @parents, conflict_strategy: "skip")

      assert %{status: "failed"} = transfer_for(@parents)
    end
  end
end
