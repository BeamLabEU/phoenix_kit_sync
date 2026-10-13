defmodule PhoenixKitSync.Web.Receiver.Helpers do
  @moduledoc """
  Pure formatting / parsing / counting helpers for the Receiver LiveView.

  None of these touch the socket — they're display formatters
  (`format_number/1`, `format_strategy/1`, `format_connection_error/1`),
  input parsers (`parse_id_list/1`, `parse_int/2`), record accessors
  (`get_record_id/1`, `get_table_info/2`, `get_schema_columns/1`,
  `filter_records_by_mode/2`), and table-count comparators
  (`fetch_local_counts/1`, `count_new_tables/2`, `count_different_tables/2`,
  `count_same_tables/2`).

  Extracted from `Receiver` in 2026-04 to shrink the LiveView module without
  changing any behavior.
  """

  use Gettext, backend: PhoenixKitSync.Gettext

  alias PhoenixKitSync.SchemaInspector

  @spec format_number(any()) :: String.t()
  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_number(_), do: "?"

  @spec format_strategy(atom()) :: String.t()
  def format_strategy(:skip), do: gettext("Skip existing")
  def format_strategy(:overwrite), do: gettext("Overwrite existing")
  def format_strategy(:merge), do: gettext("Merge data")
  def format_strategy(:append), do: gettext("Append (new IDs)")

  @spec format_connection_error(any()) :: String.t()
  def format_connection_error(:join_timeout),
    do: gettext("Connection timed out. Please check the URL and code.")

  def format_connection_error(%{"message" => msg}), do: msg

  def format_connection_error({:error, :econnrefused}),
    do: gettext("Could not connect to sender. Please check the URL.")

  def format_connection_error({:error, :nxdomain}),
    do: gettext("Could not find the sender's server. Please check the URL.")

  def format_connection_error({:error, :timeout}),
    do: gettext("Connection timed out. Please try again.")

  def format_connection_error(%WebSockex.ConnError{original: original}),
    do: format_connection_error(original)

  def format_connection_error(reason) when is_binary(reason), do: reason

  def format_connection_error(reason),
    do: gettext("Connection failed: %{reason}", reason: inspect(reason))

  @spec fetch_local_counts(list()) :: map()
  def fetch_local_counts(tables) do
    Enum.reduce(tables, %{}, fn table, acc ->
      case SchemaInspector.get_local_count(table["name"]) do
        {:ok, count} -> Map.put(acc, table["name"], count)
        _ -> acc
      end
    end)
  end

  @spec count_new_tables(list(), map()) :: non_neg_integer()
  def count_new_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      not Map.has_key?(local_counts, table["name"])
    end)
  end

  @spec count_different_tables(list(), map()) :: non_neg_integer()
  def count_different_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table["estimated_count"] || 0

      not is_nil(local_count) and local_count != sender_count
    end)
  end

  @spec count_same_tables(list(), map()) :: non_neg_integer()
  def count_same_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table["estimated_count"] || 0

      not is_nil(local_count) and local_count == sender_count
    end)
  end

  @spec parse_id_list(any()) :: list(integer())
  def parse_id_list(ids_string) when is_binary(ids_string) do
    ids_string
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_int(&1, nil))
    |> Enum.reject(&is_nil/1)
  end

  def parse_id_list(_), do: []

  @spec parse_int(any(), any()) :: any()
  def parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(_, default), do: default

  @spec get_record_id(any()) :: any()
  def get_record_id(record) when is_map(record) do
    Map.get(record, "uuid") || Map.get(record, :uuid) ||
      Map.get(record, "id") || Map.get(record, :id)
  end

  def get_record_id(_), do: nil

  @spec get_table_info(list(), String.t()) :: map() | nil
  def get_table_info(tables, table_name) do
    Enum.find(tables, fn t -> t["name"] == table_name end)
  end

  @spec get_schema_columns(any()) :: list()
  def get_schema_columns(nil), do: []

  def get_schema_columns(schema) when is_map(schema) do
    # Try both atom and string keys (data comes through JSON as strings)
    Map.get(schema, :columns) || Map.get(schema, "columns") || []
  end

  def get_schema_columns(_), do: []

  @spec filter_records_by_mode(list(), map()) :: list()
  def filter_records_by_mode(records, %{mode: :ids, ids: ids_string}) do
    ids = parse_id_list(ids_string)

    if Enum.empty?(ids) do
      records
    else
      Enum.filter(records, fn r -> get_record_id(r) in ids end)
    end
  end

  def filter_records_by_mode(records, _filter), do: records
end
