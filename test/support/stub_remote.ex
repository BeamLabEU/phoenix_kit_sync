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

  @doc "Sets the schema `table-schema` returns for `table`."
  def put_schema(table, schema),
    do: update(&put_in(&1, [Access.key(:schemas, %{}), table], schema))

  @doc "Makes `pull-data` for `table` answer `success: false` with `error` as given."
  def put_error(table, error), do: update(&put_in(&1, [:data, table], {:error, error}))

  @doc "Merges `extra` into every successful `pull-data` answer for `table`."
  def put_response_extra(table, extra),
    do: update(&put_in(&1, [Access.key(:extras, %{}), table], extra))

  @doc "Makes `pull-data` for `table` answer with `status` and `body` as given."
  def put_raw(table, status, body),
    do: update(&put_in(&1, [Access.key(:raw, %{}), table], {status, body}))

  @doc """
  Makes `pull-data` for `table` page like a sender with cursors: at most
  `size` records by `"id"`, after the request's `"after"`, with
  `"truncated"`, `"has_more"`, `"next_after"` and `"cursor"` while records
  are left.
  """
  def put_page_size(table, size),
    do: update(&put_in(&1, [Access.key(:page_sizes, %{}), table], size))

  @doc "Every `pull-data` request body for `table` since `reset/0`, oldest first."
  def pull_bodies(table),
    do: state() |> get_in([Access.key(:all_bodies, %{}), table]) |> List.wrap() |> Enum.reverse()

  @doc "The body of the last `pull-data` request for `table`, or nil."
  def last_pull_body(table), do: get_in(state(), [Access.key(:bodies, %{}), table])

  @doc "How many `pull-data` requests asked for `table` since `reset/0`."
  def pull_count(table), do: Map.get(Map.get(state(), :pulls, %{}), table, 0)

  def reset, do: Application.delete_env(:phoenix_kit_sync, @env_key)

  defp state, do: Application.get_env(:phoenix_kit_sync, @env_key, %{tables: [], data: %{}})

  defp update(fun), do: Application.put_env(:phoenix_kit_sync, @env_key, fun.(state()))

  defp count_pull(table) do
    update(fn state ->
      pulls = Map.get(state, :pulls, %{})
      Map.put(state, :pulls, Map.update(pulls, table, 1, &(&1 + 1)))
    end)
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    table = conn.body_params["table_name"]

    if List.last(conn.path_info) == "pull-data" do
      update(&put_in(&1, [Access.key(:bodies, %{}), table], conn.body_params))

      update(fn state ->
        all = Map.get(state, :all_bodies, %{})

        Map.put(
          state,
          :all_bodies,
          Map.update(all, table, [conn.body_params], &[conn.body_params | &1])
        )
      end)
    end

    {status, body} =
      case get_in(state(), [Access.key(:raw, %{}), table]) do
        {status, body} when status != 200 -> {status, body}
        _ -> {200, respond(List.last(conn.path_info), table, conn.body_params)}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp respond("list-tables", _table, _body), do: %{success: true, tables: state().tables}

  defp respond("pull-data", table, body) do
    count_pull(table)

    case Map.fetch(state().data, table) do
      {:ok, {:error, error}} ->
        %{success: false, error: error}

      {:ok, records} ->
        extra = get_in(state(), [Access.key(:extras, %{}), table]) || %{}
        size = get_in(state(), [Access.key(:page_sizes, %{}), table])
        Map.merge(page(table, records, size, body["after"]), extra)

      :error ->
        %{success: false, error: "Table not found"}
    end
  end

  defp respond("table-schema", table, _body) do
    case Map.fetch(Map.get(state(), :schemas, %{}), table) do
      {:ok, schema} -> %{success: true, schema: schema}
      :error -> %{success: false, error: "Table not found"}
    end
  end

  defp respond(_endpoint, _table, _body), do: %{success: false, error: "Not stubbed"}

  defp page(table, records, nil, _after), do: %{success: true, table: table, data: records}

  defp page(table, records, size, after_values) do
    rest =
      case after_values do
        %{"id" => id} -> Enum.drop_while(records, &(&1["id"] <= String.to_integer(id)))
        _ -> records
      end

    {data, left} = Enum.split(rest, size)
    answer = %{success: true, table: table, data: data, has_more: left != []}

    if left == [] do
      answer
    else
      Map.merge(answer, %{
        truncated: true,
        next_after: %{"id" => Integer.to_string(List.last(data)["id"])},
        cursor: "stub-cursor"
      })
    end
  end
end
