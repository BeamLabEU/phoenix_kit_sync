defmodule PhoenixKitSync.Integration.PullValueShapesTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.Test.StubRemote

  # A value is read by the type of the column it goes into, never by what
  # it looks like: text shaped like a date is a date only in a date column.
  # Both import paths, against a real table: the HTTP pull
  # (ConnectionNotifier) and the WebSocket import (DataImporter).

  @table "pvs_values"

  # Strings a column may hold that look like something else.
  @shapes [
    "2026-01-01",
    "12:30:00",
    "12:30:00.123456",
    "2026-01-01T12:30:00Z",
    "2026-01-01T12:30:00",
    "2026-01-01T12:30:00.123456+02:00",
    "3.14",
    "-0.50",
    "1e5",
    "42",
    "0190a0b2-7c3e-7d4f-8a1b-2c3d4e5f6071",
    "plain text"
  ]

  # Columns that hold text of one kind or another, and so must give back
  # exactly the string that went in.
  @text_columns ~w(t_text t_varchar t_char t_citext t_enum t_domain)

  setup do
    repo().query!("CREATE EXTENSION IF NOT EXISTS citext")
    repo().query!("CREATE TYPE pvs_kind AS ENUM (#{Enum.map_join(@shapes, ", ", &"'#{&1}'")})")
    repo().query!("CREATE DOMAIN pvs_label AS text")

    repo().query!("""
    CREATE TABLE #{@table} (
      id bigint PRIMARY KEY,
      t_text text,
      t_varchar varchar(64),
      t_char char(40),
      t_citext citext,
      t_enum pvs_kind,
      t_domain pvs_label,
      t_date date,
      t_time time,
      t_timestamp timestamp,
      t_timestamptz timestamptz,
      t_numeric numeric,
      t_float double precision,
      t_uuid uuid,
      t_json jsonb,
      t_unique text UNIQUE
    )
    """)

    StubRemote.reset()
    on_exit(&StubRemote.reset/0)

    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Stub sender #{System.unique_integer([:positive])}",
        "direction" => "receiver",
        "site_url" => StubRemote.url(),
        "status" => "active"
      })

    {:ok, connection: connection}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp import_via(:http, connection, records) do
    StubRemote.put_data(@table, records)

    {:ok, result} =
      ConnectionNotifier.pull_table_data(connection, @table, conflict_strategy: "overwrite")

    {result.imported, result.errors}
  end

  defp import_via(:http_remap, connection, records) do
    StubRemote.put_data(@table, records)

    {:ok, result, _remap} =
      ConnectionNotifier.pull_table_data_with_remap(connection, @table, %{},
        conflict_strategy: "overwrite"
      )

    {result.imported, result.errors}
  end

  defp import_via(:websocket, _connection, records) do
    {:ok, result} = DataImporter.import_records(@table, records, :overwrite)
    {result.created + result.updated, length(result.errors)}
  end

  defp stored(column, id) do
    %{rows: [[value]]} =
      repo().query!(~s[SELECT "#{column}"::text FROM #{@table} WHERE id = $1], [id])

    value
  end

  for path <- [:http, :http_remap, :websocket] do
    describe "#{path}: text columns" do
      for column <- @text_columns, {shape, index} <- Enum.with_index(@shapes) do
        test "#{column} keeps #{inspect(shape)} (case #{index})", %{connection: connection} do
          record = %{"id" => 1, unquote(column) => unquote(shape)}

          assert {1, 0} = import_via(unquote(path), connection, [record])
          assert String.trim_trailing(stored(unquote(column), 1)) == unquote(shape)
        end
      end
    end

    describe "#{path}: typed columns" do
      @typed [
        {"t_date", "2026-01-01", "2026-01-01"},
        {"t_time", "12:30:00", "12:30:00"},
        {"t_time", "12:30:00.123456", "12:30:00.123456"},
        {"t_timestamp", "2026-01-01T12:30:00", "2026-01-01 12:30:00"},
        {"t_timestamp", "2026-01-01T12:30:00.123456", "2026-01-01 12:30:00.123456"},
        {"t_numeric", "3.14", "3.14"},
        {"t_numeric", "-0.50", "-0.50"},
        {"t_numeric", "42", "42"},
        {"t_json", %{"day" => "2026-01-01", "at" => "12:30:00"},
         ~s({"at": "12:30:00", "day": "2026-01-01"})}
      ]

      for {{column, value, expected}, index} <- Enum.with_index(@typed) do
        test "#{column} reads #{inspect(value)} as its own type (case #{index})", %{
          connection: connection
        } do
          record = %{"id" => 1, unquote(column) => unquote(Macro.escape(value))}

          assert {1, 0} = import_via(unquote(path), connection, [record])
          assert stored(unquote(column), 1) == unquote(expected)
        end
      end

      test "t_timestamptz reads an instant", %{connection: connection} do
        record = %{"id" => 1, "t_timestamptz" => "2026-01-01T12:30:00Z"}

        assert {1, 0} = import_via(unquote(path), connection, [record])

        assert %{rows: [[~U[2026-01-01 12:30:00.000000Z]]]} =
                 repo().query!("SELECT t_timestamptz FROM #{@table}")
      end
    end

    describe "#{path}: a value of the wrong kind for its column" do
      test "fails its own record and leaves the others", %{connection: connection} do
        records = [
          %{"id" => 1, "t_text" => "2026-01-01"},
          %{"id" => 2, "t_date" => "not a date"},
          %{"id" => 3, "t_text" => "12:30:00"}
        ]

        assert {2, 1} = import_via(unquote(path), connection, records)
        assert stored("t_text", 1) == "2026-01-01"
        assert stored("t_text", 3) == "12:30:00"
      end
    end
  end

  describe "http_remap: matching an existing row by a unique text column" do
    # The match is a lookup with the record's value: a date-shaped string
    # compared to a text column must stay a string to match.
    for {shape, index} <- Enum.with_index(@shapes) do
      test "#{inspect(shape)} matches the local row (case #{index})", %{connection: connection} do
        repo().query!("INSERT INTO #{@table} (id, t_unique, t_text) VALUES (50, $1, 'local')", [
          unquote(shape)
        ])

        StubRemote.put_data(@table, [%{"id" => 7, "t_unique" => unquote(shape), "t_text" => "x"}])

        assert {:ok, result, remap} =
                 ConnectionNotifier.pull_table_data_with_remap(connection, @table, %{},
                   conflict_strategy: "skip"
                 )

        # Matched the row that is already here: skipped, and the sender's
        # key now maps to the local one.
        assert %{imported: 0, skipped: 1, errors: 0} = result
        assert remap[{@table, "7"}] == 50
        assert %{rows: [[1]]} = repo().query!("SELECT count(*) FROM #{@table}")
      end
    end
  end
end
