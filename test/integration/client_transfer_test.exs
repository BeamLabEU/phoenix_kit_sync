defmodule PhoenixKitSync.Integration.ClientTransferTest do
  use PhoenixKitSync.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Client
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  # Self-loop: Client pulls from the sender on the test endpoint, which
  # reads the same database, and :overwrite writes every pulled row back
  # onto itself. A trigger counts the writes per row, so a skipped row
  # ends with 0 and a row pulled twice with 2.

  setup tags do
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

    rows = Map.get(tags, :rows, 2_500)
    repo.query!("INSERT INTO ct_rows (id) SELECT generate_series(1, $1)", [rows])

    {:ok, repo: repo, rows: rows}
  end

  defp url do
    "ws://localhost:#{Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)}"
  end

  defp connect_with_code do
    {:ok, session} = PhoenixKitSync.create_session(:send)
    {:ok, client} = Client.connect(url(), session.code)
    on_exit(fn -> Client.disconnect(client) end)
    client
  end

  defp writes_per_row(repo) do
    %{rows: rows} = repo.query!("SELECT writes, count(*) FROM ct_rows GROUP BY writes")
    Map.new(rows, fn [writes, count] -> {writes, count} end)
  end

  defp assert_every_row_once(result, repo, rows) do
    assert result.updated == rows
    assert writes_per_row(repo) == %{1 => rows}
  end

  for batch_size <- [1_500, 1_000, 700] do
    test "batch_size #{batch_size} pulls every row exactly once", %{repo: repo, rows: rows} do
      assert {:ok, result} =
               Client.transfer(connect_with_code(), "ct_rows",
                 strategy: :overwrite,
                 batch_size: unquote(batch_size)
               )

      assert_every_row_once(result, repo, rows)
    end
  end

  @tag rows: 2_000
  test "a table that fills its last batch exactly is pulled once", %{repo: repo, rows: rows} do
    assert {:ok, result} =
             Client.transfer(connect_with_code(), "ct_rows",
               strategy: :overwrite,
               batch_size: 1_000
             )

    assert_every_row_once(result, repo, rows)
  end

  test "a connection that serves fewer records than the batch asks for loses none", %{
    repo: repo,
    rows: rows
  } do
    # A permanent connection caps each reply at max_records_per_request,
    # below the default batch of 500.
    {:ok, connection, token} =
      Connections.create_connection(%{
        "name" => "Capped #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://capped-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve",
        "max_records_per_request" => 300
      })

    {:ok, connection} =
      Connections.approve_connection(connection, PhoenixKitSync.TestActor.uuid())

    {:ok, client} = Client.connect("#{url()}?token=#{token}", "conn:#{connection.uuid}")
    on_exit(fn -> Client.disconnect(client) end)

    assert {:ok, result} = Client.transfer(client, "ct_rows", strategy: :overwrite)

    assert_every_row_once(result, repo, rows)
  end

  test "a sender that never reports more is read until an empty page", %{
    repo: repo,
    rows: rows
  } do
    # Stands in for an older or capped sender: it serves at most 300 records
    # per request and always says there are no more.
    test_pid = self()
    sender = spawn_link(fn -> lying_sender(test_pid) end)

    assert {:ok, result} =
             Client.transfer(sender, "ct_rows", strategy: :overwrite, batch_size: 500)

    assert_every_row_once(result, repo, rows)
  end

  # Answers Client's casts the way WebSocketClient relays a sender's replies.
  defp lying_sender(caller) do
    receive do
      {:"$websockex_cast", {:request_schema, table}} ->
        send(caller, {:sync_client, {:schema, table, %{}}})

      {:"$websockex_cast", {:request_records, table, opts}} ->
        {:ok, records} =
          DataExporter.fetch_records(table, offset: opts[:offset], limit: min(opts[:limit], 300))

        send(
          caller,
          {:sync_client,
           {:records, table, %{records: records, offset: opts[:offset], has_more: false}}}
        )
    end

    lying_sender(caller)
  end
end
