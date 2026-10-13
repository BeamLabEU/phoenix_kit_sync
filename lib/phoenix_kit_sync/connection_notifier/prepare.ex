defmodule PhoenixKitSync.ConnectionNotifier.Prepare do
  @moduledoc """
  Record-transformation and value-preparation helpers shared across the
  import paths in `ConnectionNotifier`.

  Three concerns:

  1. **`value/4`, `key_value/2`, `value/3` and `value/1`** — convert
     JSON-transported scalars back into Postgrex-ready terms. A string is
     read by the type of the column it goes into, never by its shape:
     ISO8601 text becomes a DateTime / Date / Time only in a timestamp /
     date / time column, and a numeric string a `%Decimal{}` (numeric,
     decimal) or a float (double precision, real) only in a numeric one.
     `"2026-01-01"` in a `text` column stays text. `value/3` and `value/1`
     are the forms for a caller with no column type to go by; they read by
     shape.
  2. **`numeric_column_types/1`** — maps each numeric column of a table to
     `:decimal` or `:float`. Cached once per table-import by the importer;
     empty map on error (safe "don't coerce" fallback).
  3. **Record field helpers** (`get_field/2`, `put_field/3`, `drop_field/2`,
     `normalize_keys/1`) — records arrive with either string or atom keys
     depending on whether they came through JSON or internal code. These
     helpers access/modify fields uniformly without creating atoms from
     untrusted data.

  All functions are pure or depend only on `SchemaInspector` (for column
  introspection) — none touch HTTP, the socket, or the websocket client.
  """

  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.ExtensionTypes
  alias PhoenixKitSync.SchemaInspector

  @typedoc """
  A column's type as the importer names it: the `information_schema`
  `data_type`, or `{:array, element_type}` for an array column.
  """
  @type column_type :: String.t() | {:array, String.t() | nil}

  # "double precision" is one type name of two words.
  @numeric_types %{
    "numeric" => :decimal,
    "decimal" => :decimal,
    "double precision" => :float,
    "real" => :float
  }

  # ===========================================
  # value/4 — reads a string by its column's type
  # ===========================================

  @datetime_types ["timestamp without time zone", "timestamp with time zone"]
  @time_types ["time without time zone", "time with time zone"]

  @doc """
  Prepares `value` for `column`, whose SQL type `column_types` names
  (`%{column => information_schema data_type}`). A string is parsed only as
  what that type holds; in any other column (text, varchar, citext, an
  enum, ...) it is passed as it came. `numeric_cols` is the map
  `numeric_column_types/1` returns.

  A column `column_types` does not name is read by shape, as `value/3` does.

  An array column is named `{:array, element_type}` and takes a list, whose
  elements are read by the element type
  (`PhoenixKitSync.DataImporter.prepare_array/2`). A list for any other
  column (a json value) is passed as it came.

  A map is read as the base64 wrapper of bytes
  (`%{"__phoenix_kit_binary__" => ...}`) only in a `bytea` or `uuid` column;
  in any other column the type of which is known it is passed as it came,
  so a json object of that shape stays an object.
  """
  @spec value(any(), String.t(), %{String.t() => :decimal | :float}, %{
          String.t() => column_type() | nil
        }) :: any()
  def value(list, column, _numeric_cols, column_types)
      when is_list(list) and is_binary(column) and is_map(column_types) do
    case Map.get(column_types, column) do
      {:array, element_type} -> DataImporter.prepare_array(list, element_type)
      _not_an_array -> list
    end
  end

  def value(value, column, numeric_cols, column_types)
      when is_binary(value) and is_binary(column) and is_map(column_types) do
    case Map.get(column_types, column) do
      nil -> value(value, column, numeric_cols)
      type -> typed_string(value, type, Map.get(numeric_cols, column))
    end
  end

  # A map is the wrapper bytes travel in only where bytes are written: a
  # bytea or a uuid column. In a column of any other known type (json and
  # jsonb above all) an object of the same shape is the value itself.
  def value(%{} = value, column, _numeric_cols, column_types)
      when is_binary(column) and is_map(column_types) do
    typed_map(value, Map.get(column_types, column))
  end

  def value(value, _column, _numeric_cols, _column_types), do: value(value)

  @binary_types ["bytea", "uuid"]

  defp typed_map(value, type) when type in @binary_types or is_nil(type), do: value(value)
  defp typed_map(value, _type), do: value

  @doc """
  Prepares a key value (a primary key, a unique column) for a lookup in a
  column of SQL type `type`. Read by that type like `value/4`; by shape
  when `type` is nil.
  """
  @spec key_value(any(), column_type() | nil) :: any()
  def key_value(value, type) when is_binary(value) and is_binary(type),
    do: typed_string(value, type, @numeric_types[type])

  def key_value(list, {:array, element_type}) when is_list(list),
    do: DataImporter.prepare_array(list, element_type)

  def key_value(%{} = value, type), do: typed_map(value, type)

  def key_value(value, _type), do: value(value)

  defp typed_string(value, type, numeric_kind) do
    parsed =
      cond do
        type in @datetime_types -> parse_datetime_string(value)
        type == "date" -> parse_date_string(value)
        type in @time_types -> parse_time_string(value)
        numeric_kind -> parse_numeric_string(value, numeric_kind)
        type in ["interval", "inet", "cidr", "macaddr"] -> parse_extension(type, value)
        true -> nil
      end

    parsed || value
  end

  # An interval, an inet or a macaddr travels as text and is bound as the
  # struct Postgrex takes for it.
  defp parse_extension(type, value) do
    case ExtensionTypes.parse(type, value) do
      {:ok, struct} -> struct
      :error -> nil
    end
  end

  # ===========================================
  # value/3 — scopes decimal coercion to numeric columns
  # ===========================================

  # The third argument is the map numeric_column_types/1 returns: a numeric
  # string in a double precision / real column becomes a float, since
  # Postgrex takes neither a string nor a Decimal there.
  @spec value(any(), String.t(), %{String.t() => :decimal | :float}) :: any()
  def value(value, column, column_types)
      when is_binary(value) and is_binary(column) and is_map(column_types) do
    parse_datetime_string(value) || parse_date_string(value) || parse_time_string(value) ||
      parse_numeric_string(value, Map.get(column_types, column)) ||
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

  @doc """
  Maps each numeric column of `table_name` to the term a numeric string in
  it should become: `:decimal` for numeric/decimal, `:float` for double
  precision/real. Empty map on error.
  """
  @spec numeric_column_types(String.t()) :: %{String.t() => :decimal | :float}
  def numeric_column_types(table_name) do
    case SchemaInspector.get_schema(table_name) do
      {:ok, %{columns: columns}} ->
        for col <- columns, kind = @numeric_types[col.type], into: %{}, do: {col.name, kind}

      _ ->
        %{}
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

  # In a column known to be numeric, any numeric string becomes a Decimal:
  # the exporters send "5" for a whole number and "1.5E+3" for one with an
  # exponent, and Postgrex binds a string to numeric only as a Decimal.
  @numeric_regex ~r/\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/
  defp parse_numeric_string(value, :decimal) do
    if Regex.match?(@numeric_regex, value), do: new_decimal(value)
  end

  defp parse_numeric_string(value, :float), do: parse_float_string(value)
  defp parse_numeric_string(_value, nil), do: nil

  @float_regex ~r/\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/

  defp parse_float_string(value) do
    # Float.parse/1 does not take every match: "1e400" is out of range.
    # Leaving the string makes it a failed record, not a crash.
    with true <- Regex.match?(@float_regex, value),
         {float, ""} <- Float.parse(value) do
      float
    else
      _ -> nil
    end
  end

  # Decimal-like strings: "0.00", "123.45", "-99.99". With no column type to
  # go by, plain integers like "123" (no dot) are left as strings.
  @decimal_regex ~r/^-?\d+\.\d+$/
  defp parse_decimal_string(value) do
    if Regex.match?(@decimal_regex, value), do: new_decimal(value)
  end

  defp new_decimal(value) do
    Decimal.new(value)
  rescue
    _ -> nil
  end
end
