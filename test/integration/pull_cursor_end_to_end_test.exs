defmodule PhoenixKitSync.Integration.PullCursorEndToEndTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  # This module's receiver against this module's sender, over HTTP: the
  # receiver pulls from the test endpoint, which reads the same database,
  # and :overwrite writes every pulled row back onto itself. A trigger
  # counts the writes per row, so a row the pages skipped ends with 0 and a
  # row they carried twice with 2.

  @limit 4

  setup do
    Sandbox.mode(TestRepo, {:shared, self()})
    PhoenixKitSync.enable_system()

    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)

    {:ok, sender, token} =
      Connections.create_connection(%{
        "name" => "Sender side",
        "direction" => "sender",
        "site_url" => "https://receiver-#{System.unique_integer([:positive])}.example.com",
        "status" => "active",
        "max_records_per_request" => @limit
      })

    {:ok, receiver, _token} =
      Connections.create_connection(%{
        "name" => "Receiver side",
        "direction" => "receiver",
        "site_url" => "http://localhost:#{port}",
        "auth_token" => token,
        "status" => "active"
      })

    repo = PhoenixKit.RepoHelper.repo()

    repo.query!("""
    CREATE FUNCTION e2e_count_write() RETURNS trigger AS $$
    BEGIN
      NEW.writes := OLD.writes + 1;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    {:ok, sender: sender, receiver: receiver, repo: repo}
  end

  defp table!(repo, name, key_ddl, insert) do
    repo.query!("CREATE TABLE #{name} (#{key_ddl}, writes int NOT NULL DEFAULT 0)")
    repo.query!(insert)

    repo.query!(
      "CREATE TRIGGER #{name}_writes BEFORE UPDATE ON #{name} " <>
        "FOR EACH ROW EXECUTE FUNCTION e2e_count_write()"
    )
  end

  defp writes(repo, name) do
    %{rows: rows} = repo.query!("SELECT writes, count(*) FROM #{name} GROUP BY writes")
    Map.new(rows, fn [writes, count] -> {writes, count} end)
  end

  @tables [
    {"e2e_uuid", "uuid uuid PRIMARY KEY",
     "INSERT INTO e2e_uuid (uuid) SELECT md5(g::text)::uuid FROM generate_series(1, 23) g"},
    {"e2e_text", "code text PRIMARY KEY",
     "INSERT INTO e2e_text (code) SELECT 'k' || g FROM generate_series(1, 23) g"},
    {"e2e_pairs", "a int, b text, PRIMARY KEY (a, b)",
     "INSERT INTO e2e_pairs (a, b) SELECT g % 3, 'b' || g FROM generate_series(1, 23) g"},
    {"e2e_int", "id bigint PRIMARY KEY",
     "INSERT INTO e2e_int (id) SELECT g FROM generate_series(1, 23) g"}
  ]

  for {name, key_ddl, insert} <- @tables, path <- [:plain, :remap] do
    test "#{name} past the sender's limit is pulled whole, each row once (#{path})", %{
      sender: sender,
      receiver: receiver,
      repo: repo
    } do
      table!(repo, unquote(name), unquote(key_ddl), unquote(insert))

      result =
        case unquote(path) do
          :plain ->
            ConnectionNotifier.pull_table_data(receiver, unquote(name),
              conflict_strategy: "overwrite"
            )

          :remap ->
            with {:ok, result, _remap} <-
                   ConnectionNotifier.pull_table_data_with_remap(receiver, unquote(name), %{},
                     conflict_strategy: "overwrite"
                   ),
                 do: {:ok, result}
        end

      assert {:ok, result} = result
      refute Map.has_key?(result, :truncated)
      assert result.errors == 0
      assert writes(repo, unquote(name)) == %{1 => 23}

      # Six pages, one download.
      counted = Connections.get_connection!(sender.uuid)
      assert counted.downloads_used == 1
      assert counted.records_downloaded == 23
    end
  end

  test "the sender's record allowance cuts the pull where it runs out", %{
    sender: sender,
    receiver: receiver,
    repo: repo
  } do
    {name, key_ddl, insert} = List.last(@tables)
    table!(repo, name, key_ddl, insert)
    {:ok, _} = Connections.update_connection(sender, %{max_records_total: 10})

    assert {:error, :record_limit_reached} =
             ConnectionNotifier.pull_table_data(receiver, name, conflict_strategy: "overwrite")

    # The first ten rows by key came, once each; no row past the allowance.
    assert writes(repo, name) == %{1 => 10, 0 => 13}
    assert Connections.get_connection!(sender.uuid).records_downloaded == 10
  end
end
