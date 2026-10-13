defmodule PhoenixKitSync.PeerData do
  @moduledoc false

  # Schema fields reach both DDL preparation and templates. Normalisation
  # alone cannot make a map-valued name or type safe to render.
  @spec valid_schema?(term()) :: boolean()
  def valid_schema?(%{"columns" => columns} = schema) when is_list(columns) do
    Enum.all?(columns, &valid_column?/1) and
      string_list?(Map.get(schema, "primary_key", []))
  end

  def valid_schema?(_schema), do: false

  defp valid_column?(column) when is_map(column) do
    is_binary(column["name"] || column["column_name"]) and
      is_binary(column["type"] || column["data_type"]) and
      (is_nil(column["element_type"]) or is_binary(column["element_type"]))
  end

  defp valid_column?(_column), do: false

  @spec tables(term()) :: {:ok, [map()]} | {:error, :invalid_response}
  def tables(tables) when is_list(tables) do
    if Enum.all?(tables, &valid_table?/1),
      do: {:ok, Enum.map(tables, &normalize_table/1)},
      else: {:error, :invalid_response}
  end

  def tables(_tables), do: {:error, :invalid_response}

  defp valid_table?(%{"name" => name}), do: is_binary(name)
  defp valid_table?(_table), do: false

  defp normalize_table(table) do
    table
    |> Map.update("row_count", 0, &nonnegative_integer/1)
    |> Map.update("size_bytes", 0, &nonnegative_integer/1)
    |> Map.update("depends_on", [], &strings/1)
    |> Map.update("checksum", nil, fn value -> if is_binary(value), do: value end)
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: 0
  defp strings(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp strings(_value), do: []
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
end
