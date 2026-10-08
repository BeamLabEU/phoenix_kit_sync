defmodule PhoenixKitSync.Integration.ClientTransferTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Client
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  # Self-loop: Client pulls from the sender on the test endpoint, which
  # reads the same database, and :overwrite writes every pulled row back
  # onto itself. A trigger counts the writes per row, so a skipped row
  # ends with 0 and a row pulled twice with 2.

  setup do
    Sandbox.mode(TestRepo, {:shared, self()})
    PhoenixKitSync.enable_system()

    repo = PhoenixKit.RepoHelper.repo()
    repo.query!("CREATE TABLE ct_rows (id int PRIMARY KEY, writes int NOT NULL DEFAULT 0)")

    repo.query!("""
    CREATE FUNCTION ct_rows_count_write() RETURNS trigger AS $$
    BEGIN
      NEW.writes := OLD.writes + 1;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    repo.query!(
      "CREATE TRIGGER ct_rows_writes BEFORE UPDATE ON ct_rows " <>
        "FOR EACH ROW EXECUTE FUNCTION ct_rows_count_write()"
    )

    repo.query!("INSERT INTO ct_rows (id) SELECT generate_series(1, 2500)")

    {:ok, session} = PhoenixKitSync.create_session(:send)
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)
    {:ok, client} = Client.connect("ws://localhost:#{port}", session.code)
    on_exit(fn -> if Process.alive?(client), do: Client.disconnect(client) end)

    {:ok, client: client, repo: repo}
  end

  defp writes_per_row(repo) do
    %{rows: rows} = repo.query!("SELECT writes, count(*) FROM ct_rows GROUP BY writes")
    Map.new(rows, fn [writes, count] -> {writes, count} end)
  end

  for batch_size <- [1_500, 1_000, 700] do
    test "batch_size #{batch_size} pulls every row exactly once", %{client: client, repo: repo} do
      assert {:ok, result} =
               Client.transfer(client, "ct_rows",
                 strategy: :overwrite,
                 batch_size: unquote(batch_size)
               )

      assert result.updated == 2_500
      assert writes_per_row(repo) == %{1 => 2_500}
    end
  end
end
