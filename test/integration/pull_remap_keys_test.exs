defmodule PhoenixKitSync.Integration.PullRemapKeysTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote

  # A parent row the receiver already has under another key is matched by
  # its unique columns; the remap then sends the children's FK to the local
  # parent. The values arrive in the sender's wire form: a uuid as a
  # base64-wrapped 16-byte binary, an integer as a JSON number.
  #
  # With overwrite or merge, a matched row (same key, or same unique
  # columns under another key) takes the sender's values; with skip it
  # stays as it was.

  setup do
    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_uuid_parents (uuid uuid PRIMARY KEY, name text NOT NULL UNIQUE)
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_uuid_children (
      uuid uuid PRIMARY KEY,
      parent_uuid uuid REFERENCES rk_uuid_parents(uuid)
    )
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_int_parents (id bigint PRIMARY KEY, name text NOT NULL UNIQUE)
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_int_children (
      id bigint PRIMARY KEY,
      parent_id bigint REFERENCES rk_int_parents(id)
    )
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_slugs (
      uuid uuid PRIMARY KEY,
      parent_uuid uuid NOT NULL REFERENCES rk_uuid_parents(uuid),
      slug text NOT NULL,
      note text,
      UNIQUE (parent_uuid, slug)
    )
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_slug_refs (
      uuid uuid PRIMARY KEY,
      slug_uuid uuid REFERENCES rk_slugs(uuid)
    )
    """)

    repo().query!("""
    CREATE TABLE IF NOT EXISTS rk_items (
      code text PRIMARY KEY,
      name text NOT NULL UNIQUE,
      note text,
      extra text
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

  defp wire_uuid(uuid), do: %{"__phoenix_kit_binary__" => Base.encode64(Ecto.UUID.dump!(uuid))}

  defp pull(connection, table, remap, strategy) do
    ConnectionNotifier.pull_table_data_with_remap(connection, table, remap,
      conflict_strategy: strategy
    )
  end

  describe "uuid keys on the wire" do
    test "a child's uuid FK follows its parent's remap", %{connection: connection} do
      local_parent = UUIDv7.generate()
      remote_parent = UUIDv7.generate()
      child = UUIDv7.generate()

      repo().query!("INSERT INTO rk_uuid_parents VALUES ($1, 'shelves')", [
        Ecto.UUID.dump!(local_parent)
      ])

      StubRemote.put_data("rk_uuid_parents", [
        %{"uuid" => wire_uuid(remote_parent), "name" => "shelves"}
      ])

      StubRemote.put_data("rk_uuid_children", [
        %{"uuid" => wire_uuid(child), "parent_uuid" => wire_uuid(remote_parent)}
      ])

      assert {:ok, %{imported: 0, skipped: 1}, remap} =
               pull(connection, "rk_uuid_parents", %{}, "skip")

      # Keyed by the canonical uuid string, whatever form it travelled in.
      assert Map.keys(remap) == [{"rk_uuid_parents", remote_parent}]

      assert {:ok, %{imported: 1, errors: 0}, _} =
               pull(connection, "rk_uuid_children", remap, "skip")

      assert %{rows: [[^local_parent]]} =
               repo().query!("SELECT parent_uuid::text FROM rk_uuid_children")
    end

    test "an FK sent as uuid text in another case still follows the remap", %{
      connection: connection
    } do
      local_parent = UUIDv7.generate()
      remote_parent = UUIDv7.generate()

      repo().query!("INSERT INTO rk_uuid_parents VALUES ($1, 'shelves')", [
        Ecto.UUID.dump!(local_parent)
      ])

      StubRemote.put_data("rk_uuid_parents", [
        %{"uuid" => wire_uuid(remote_parent), "name" => "shelves"}
      ])

      StubRemote.put_data("rk_uuid_children", [
        %{"uuid" => wire_uuid(UUIDv7.generate()), "parent_uuid" => String.upcase(remote_parent)}
      ])

      assert {:ok, _, remap} = pull(connection, "rk_uuid_parents", %{}, "skip")

      assert {:ok, %{imported: 1, errors: 0}, _} =
               pull(connection, "rk_uuid_children", remap, "skip")

      assert %{rows: [[^local_parent]]} =
               repo().query!("SELECT parent_uuid::text FROM rk_uuid_children")
    end
  end

  describe "a malformed binary wrapper" do
    # The wrapper is the sender's data: a wrapper around something that is
    # not base64 text must end as a failed record, never hang the import.
    for {label, inner} <- [{"null", nil}, {"a number", 1}, {"not base64", "%%%"}] do
      test "in an FK column (#{label}) fails the record and returns", %{connection: connection} do
        StubRemote.put_data("rk_uuid_children", [
          %{
            "uuid" => wire_uuid(UUIDv7.generate()),
            "parent_uuid" => %{"__phoenix_kit_binary__" => unquote(inner)}
          }
        ])

        task = Task.async(fn -> pull(connection, "rk_uuid_children", %{}, "skip") end)

        assert {:ok, {:ok, %{imported: 0, errors: 1}, %{}}} = Task.yield(task, 5_000),
               "the import did not return"
      end
    end
  end

  describe "a unique set that holds a remapped FK" do
    # rk_slugs is unique on (parent_uuid, slug). The sender's slug points at
    # the sender's parent; only after the FK is remapped does it match the
    # local slug, which a grandchild then has to reach.
    for strategy <- ["skip", "overwrite", "merge"] do
      test "matches the local row, and a grandchild follows it (#{strategy})", %{
        connection: connection
      } do
        strategy = unquote(strategy)
        [lp, rp, lc, rc] = for _ <- 1..4, do: UUIDv7.generate()

        repo().query!("INSERT INTO rk_uuid_parents VALUES ($1, 'shelves')", [Ecto.UUID.dump!(lp)])

        repo().query!("INSERT INTO rk_slugs VALUES ($1, $2, 'oak', 'local')", [
          Ecto.UUID.dump!(lc),
          Ecto.UUID.dump!(lp)
        ])

        StubRemote.put_data("rk_uuid_parents", [%{"uuid" => wire_uuid(rp), "name" => "shelves"}])

        StubRemote.put_data("rk_slugs", [
          %{
            "uuid" => wire_uuid(rc),
            "parent_uuid" => wire_uuid(rp),
            "slug" => "oak",
            "note" => "remote"
          }
        ])

        StubRemote.put_data("rk_slug_refs", [
          %{"uuid" => wire_uuid(UUIDv7.generate()), "slug_uuid" => wire_uuid(rc)}
        ])

        {:ok, _, remap} = pull(connection, "rk_uuid_parents", %{}, strategy)
        assert {:ok, %{errors: 0}, remap} = pull(connection, "rk_slugs", remap, strategy)
        assert Map.has_key?(remap, {"rk_slugs", rc})

        assert {:ok, %{imported: 1, errors: 0}, _} =
                 pull(connection, "rk_slug_refs", remap, strategy)

        %{rows: [[uuid, note]]} = repo().query!("SELECT uuid::text, note FROM rk_slugs")
        assert uuid == lc
        assert note == if(strategy == "skip", do: "local", else: "remote")

        assert %{rows: [[^lc]]} = repo().query!("SELECT slug_uuid::text FROM rk_slug_refs")
      end
    end
  end

  describe "integer keys" do
    test "a child's integer FK follows its parent's remap", %{connection: connection} do
      repo().query!("INSERT INTO rk_int_parents VALUES (7, 'shelves')")

      StubRemote.put_data("rk_int_parents", [%{"id" => 42, "name" => "shelves"}])
      StubRemote.put_data("rk_int_children", [%{"id" => 1, "parent_id" => 42}])

      assert {:ok, %{skipped: 1}, remap} = pull(connection, "rk_int_parents", %{}, "skip")
      assert remap == %{{"rk_int_parents", "42"} => 7}

      assert {:ok, %{imported: 1, errors: 0}, _} =
               pull(connection, "rk_int_children", remap, "skip")

      assert %{rows: [[7]]} = repo().query!("SELECT parent_id FROM rk_int_children")
    end

    test "a remapped FK is not remapped a second time", %{connection: connection} do
      # A caller's remap where one local key is also another sender key:
      # a child of sender 42 must end at 7, not follow the chain on to 3.
      repo().query!("INSERT INTO rk_int_parents VALUES (7, 'a'), (3, 'b')")
      StubRemote.put_data("rk_int_children", [%{"id" => 1, "parent_id" => 42}])

      remap = %{{"rk_int_parents", "42"} => 7, {"rk_int_parents", "7"} => 3}

      assert {:ok, %{imported: 1}, _} = pull(connection, "rk_int_children", remap, "skip")
      assert %{rows: [[7]]} = repo().query!("SELECT parent_id FROM rk_int_children")
    end
  end

  describe "overwrite and merge on a single-column key" do
    defp items do
      repo().query!("SELECT code, name, note, extra FROM rk_items ORDER BY code").rows
    end

    test "merge keeps the local value where the sender sends NULL to a NOT NULL column", %{
      connection: connection
    } do
      repo().query!("INSERT INTO rk_items VALUES ('i1', 'shelf', 'local note', 'old')")

      StubRemote.put_data("rk_items", [
        %{"code" => "i1", "name" => nil, "note" => "new", "extra" => nil}
      ])

      assert {:ok, %{imported: 1, errors: 0}, _} = pull(connection, "rk_items", %{}, "merge")
      assert items() == [["i1", "shelf", "new", "old"]]
    end

    test "merge still refuses a NULL in a NOT NULL column of a new row", %{
      connection: connection
    } do
      StubRemote.put_data("rk_items", [%{"code" => "new", "name" => nil, "note" => "x"}])

      assert {:ok, %{imported: 0, errors: 1}, _} = pull(connection, "rk_items", %{}, "merge")
      assert items() == []
    end

    test "merge keeps local values where the sender sends NULL", %{connection: connection} do
      repo().query!("INSERT INTO rk_items VALUES ('i1', 'shelf', 'local note', 'old')")

      StubRemote.put_data("rk_items", [
        %{"code" => "i1", "name" => "shelf", "note" => nil, "extra" => "new"}
      ])

      assert {:ok, %{imported: 1, skipped: 0, errors: 0}, _} =
               pull(connection, "rk_items", %{}, "merge")

      assert items() == [["i1", "shelf", "local note", "new"]]
    end

    test "overwrite updates the local row matched by unique columns under another key", %{
      connection: connection
    } do
      repo().query!("INSERT INTO rk_items VALUES ('local', 'shelf', 'local note', 'old')")

      StubRemote.put_data("rk_items", [
        %{"code" => "remote", "name" => "shelf", "note" => nil, "extra" => "new"}
      ])

      assert {:ok, %{imported: 1, skipped: 0, errors: 0}, remap} =
               pull(connection, "rk_items", %{}, "overwrite")

      assert remap == %{{"rk_items", "remote"} => "local"}
      assert items() == [["local", "shelf", nil, "new"]]
    end

    test "merge on a unique-column match keeps the local key and NULL-field values", %{
      connection: connection
    } do
      repo().query!("INSERT INTO rk_items VALUES ('local', 'shelf', 'local note', 'old')")

      StubRemote.put_data("rk_items", [
        %{"code" => "remote", "name" => "shelf", "note" => nil, "extra" => "new"}
      ])

      assert {:ok, %{imported: 1}, _} = pull(connection, "rk_items", %{}, "merge")
      assert items() == [["local", "shelf", "local note", "new"]]
    end

    test "skip on a unique-column match records the remap and changes nothing", %{
      connection: connection
    } do
      repo().query!("INSERT INTO rk_items VALUES ('local', 'shelf', 'local note', 'old')")

      StubRemote.put_data("rk_items", [
        %{"code" => "remote", "name" => "shelf", "note" => nil, "extra" => "new"}
      ])

      assert {:ok, %{imported: 0, skipped: 1}, remap} =
               pull(connection, "rk_items", %{}, "skip")

      assert remap == %{{"rk_items", "remote"} => "local"}
      assert items() == [["local", "shelf", "local note", "old"]]
    end
  end
end
