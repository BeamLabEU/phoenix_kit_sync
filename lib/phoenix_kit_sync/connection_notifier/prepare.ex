defmodule PhoenixKitSync.ConnectionNotifier.Prepare do
  @moduledoc """
  Record-transformation and value-preparation helpers shared across the
  import paths in `ConnectionNotifier`.

  Three concerns:

  1. **`value/1` and `value/3`** — convert JSON-transported scalars back
     into Postgrex-ready terms. ISO8601 strings become DateTime / Date /
     Time. Decimal-like strings become `%Decimal{}` only when the target
     column is numeric (the 3-arity form) — the broad 1-arity form is
     kept for the PK/unique-key lookup paths where values are known keys,
     not free-text.
  2. **`numeric_columns/1`** — returns the list of column names whose type
     is `numeric`/`decimal`/`double precision`/`real` for a given table.
     Used by the importer to scope decimal-string detection. Cached once
     per table-import; empty list on error (safe "don't coerce" fallback).
  3. **Record field helpers** (`get_field/2`, `put_field/3`, `drop_field/2`,
     `normalize_keys/1`) — records arrive with either string or atom keys
     depending on whether they came through JSON or internal code. These
     helpers access/modify fields uniformly without creating atoms from
     untrusted data.

  Extracted from `ConnectionNotifier` in 2026-04. All functions are pure
  or depend only on `SchemaInspector` (for column introspection) — none
  touch HTTP, the socket, or the websocket client.
  """

  alias PhoenixKitSync.SchemaInspector

  # ===========================================
  # value/3 — scopes decimal coercion to numeric columns
  # ===========================================

  @spec value(any(), String.t(), list(String.t())) :: any()
  def value(value, column, numeric_cols)
      when is_binary(value) and is_binary(column) and is_list(numeric_cols) do
    parse_datetime_string(value) || parse_date_string(value) || parse_time_string(value) ||
      if(column in numeric_cols, do: parse_decimal_string(value)) ||
      value
  end

  def value(value, _column, _numeric_cols), do: value(value)

  # ===========================================
  # value/1 — broad decimal coercion (for known-key values only)
  # ===========================================

  @spec value(any()) :: any()
  def value(value) when is_binary(value) do
    parse_datetime_string(value) || parse_date_string(value) || parse_time_string(value) ||
      parse_decimal_string(value) || value
  end

  def value(%{"__phoenix_kit_binary__" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> binary
      :error -> encoded
    end
  end

  def value(value), do: value

  # ===========================================
  # Column-type caching
  # ===========================================

  @spec numeric_columns(String.t()) :: list(String.t())
  def numeric_columns(table_name) do
    case SchemaInspector.get_schema(table_name) do
      {:ok, %{columns: columns}} ->
        columns
        |> Enum.filter(fn col -> col.type in ~w[numeric decimal double precision real] end)
        |> Enum.map(& &1.name)

      _ ->
        []
    end
  end

  # ===========================================
  # Record field helpers
  # ===========================================

  @spec get_field(map(), String.t()) :: any()
  def get_field(record, field) when is_binary(field) do
    case Map.get(record, field) do
      nil -> Map.get(record, String.to_existing_atom(field))
      val -> val
    end
  rescue
    ArgumentError -> nil
  end

  @spec put_field(map(), String.t(), any()) :: map()
  def put_field(record, field, value) when is_binary(field) do
    record
    |> Map.delete(field)
    |> Map.reject(fn {k, _} -> is_atom(k) and Atom.to_string(k) == field end)
    |> Map.put(field, value)
  end

  @spec drop_field(map(), String.t()) :: map()
  def drop_field(record, field) when is_binary(field) do
    record
    |> Map.delete(field)
    |> Map.reject(fn {k, _} -> is_atom(k) and Atom.to_string(k) == field end)
  end

  @spec normalize_keys(map()) :: map()
  def normalize_keys(record) when is_map(record) do
    Map.new(record, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ===========================================
  # ISO8601 parsers
  # ===========================================

  @datetime_regex ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/
  defp parse_datetime_string(value) do
    if Regex.match?(@datetime_regex, value) do
      case DateTime.from_iso8601(value) do
        {:ok, dt, _offset} -> dt
        _ -> parse_naive_datetime(value)
      end
    end
  end

  defp parse_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end

  @date_regex ~r/^\d{4}-\d{2}-\d{2}$/
  defp parse_date_string(value) do
    if Regex.match?(@date_regex, value) do
      case Date.from_iso8601(value) do
        {:ok, d} -> d
        _ -> nil
      end
    end
  end

  @time_regex ~r/^\d{2}:\d{2}:\d{2}(\.\d+)?$/
  defp parse_time_string(value) do
    if Regex.match?(@time_regex, value) do
      case Time.from_iso8601(value) do
        {:ok, t} -> t
        _ -> nil
      end
    end
  end

  # Decimal-like strings: "0.00", "123.45", "-99.99". Plain integers like
  # "123" (no dot) are left as strings — Postgrex handles integer→numeric
  # binds natively.
  @decimal_regex ~r/^-?\d+\.\d+$/
  defp parse_decimal_string(value) do
    if Regex.match?(@decimal_regex, value) do
      Decimal.new(value)
    end
  rescue
    _ -> nil
  end
end
