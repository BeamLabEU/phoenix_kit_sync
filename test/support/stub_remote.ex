defmodule PhoenixKitSync.Test.StubRemote do
  @moduledoc """
  A canned "sender" site for receiver-side pull tests.

  `Test.Router` forwards `/stub-remote/*` here, so a connection whose
  `site_url` is `url/0` gets its `list-tables` and `pull-data` answers
  from whatever the test put in with `put_tables/1` and `put_data/2`,
  whatever URL prefix the notifier adds. The real `ApiController` reads
  the same database the receiver writes to, so it cannot serve rows the
  receiver does not have yet; this stub can.

  State lives in app env, so tests using it must be `async: false`.
  `reset/0` clears it.
  """

  @behaviour Plug

  import Plug.Conn

  @env_key :stub_remote

  @doc "Base URL to use as a connection's `site_url`."
  def url do
    port = Application.fetch_env!(:phoenix_kit_sync, :test_endpoint_port)
    "http://localhost:#{port}/stub-remote"
  end

  @doc "Sets the table list returned by `list-tables`."
  def put_tables(tables), do: update(&Map.put(&1, :tables, tables))

  @doc "Sets the records `pull-data` returns for `table`."
  def put_data(table, records), do: update(&put_in(&1, [:data, table], records))

  def reset, do: Application.delete_env(:phoenix_kit_sync, @env_key)

  defp state, do: Application.get_env(:phoenix_kit_sync, @env_key, %{tables: [], data: %{}})

  defp update(fun), do: Application.put_env(:phoenix_kit_sync, @env_key, fun.(state()))

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    body =
      case List.last(conn.path_info) do
        "list-tables" ->
          %{success: true, tables: state().tables}

        "pull-data" ->
          table = conn.body_params["table_name"]

          case Map.fetch(state().data, table) do
            {:ok, records} -> %{success: true, table: table, data: records}
            :error -> %{success: false, error: "Table not found"}
          end

        _ ->
          %{success: false, error: "Not stubbed"}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
