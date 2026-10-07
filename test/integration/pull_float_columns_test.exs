defmodule PhoenixKitSync.Integration.PullFloatColumnsTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.ConnectionNotifier
  alias PhoenixKitSync.ConnectionNotifier.Prepare
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.StubRemote

  # "double precision" is one type name of two words; the numeric-column
  # list must not split it. A value can reach such a column as a JSON
  # number or as a string (a sender that serialised it as text).

  setup do
    repo().query!("""
    CREATE TABLE IF NOT EXISTS fc_measures (
      code text PRIMARY KEY,
      ratio double precision,
      weight real,
      price numeric(10,2)
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

  test "numeric_columns/1 lists double precision, real and numeric columns" do
    assert Enum.sort(Prepare.numeric_columns("fc_measures")) == ["price", "ratio", "weight"]
  end

  test "float columns import from numbers and from numeric strings", %{connection: connection} do
    StubRemote.put_data("fc_measures", [
      %{"code" => "a", "ratio" => 0.5, "weight" => 2, "price" => "3.50"},
      %{"code" => "b", "ratio" => "0.25", "weight" => "1.5", "price" => "4.00"}
    ])

    assert {:ok, %{imported: 2, errors: 0}, _} =
             ConnectionNotifier.pull_table_data_with_remap(connection, "fc_measures", %{},
               conflict_strategy: "skip"
             )

    %{rows: rows} =
      repo().query!("SELECT code, ratio, weight, price::text FROM fc_measures ORDER BY code")

    assert rows == [["a", 0.5, 2.0, "3.50"], ["b", 0.25, 1.5, "4.00"]]
  end
end
