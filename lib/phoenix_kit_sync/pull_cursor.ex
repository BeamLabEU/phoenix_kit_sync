defmodule PhoenixKitSync.PullCursor do
  @moduledoc """
  The keyset cursor of a bulk pull: where a page starts and where the next
  one continues.

  A pull answers at most `max_records_per_request` rows in primary-key
  order. When rows are left, the sender names the last row's key values
  (`"next_after"`), and the receiver asks for the page after them with
  `"after"`. Both are a map of every primary-key column to the value's
  text, e.g. `%{"uuid" => "0190…"}` or `%{"order_id" => "7", "line" => "3"}`.

  The page after a key is a row-value comparison in the columns' own types,
  `("a", "b") > ($1::text::bigint, $2::text::uuid)`, so a composite key and
  a non-integer key continue exactly where `ORDER BY "a", "b"` left off.
  Values are bound, never interpolated; the only text that reaches the SQL
  is a quoted column name and a type name from the list below.

  Keys of other types (a float, an array, an enum) have no cursor: such a
  table answers its first page and `"truncated"`, as a sender without
  cursors does.
  """

  @typedoc "A primary key as `{column, information_schema data_type}` pairs, in key order."
  @type key :: [{String.t(), String.t() | nil}]

  @casts %{
    "uuid" => "uuid",
    "smallint" => "bigint",
    "integer" => "bigint",
    "bigint" => "bigint",
    "text" => "text",
    "character varying" => "text",
    "numeric" => "numeric",
    "date" => "date",
    "timestamp without time zone" => "timestamp",
    "timestamp with time zone" => "timestamptz"
  }

  @max_value_bytes 1024

  @doc "Whether every column of `key` has a type a cursor can continue from."
  @spec supported?(key()) :: boolean()
  def supported?([]), do: false
  def supported?(key), do: Enum.all?(key, fn {_col, type} -> is_map_key(@casts, type) end)

  @doc """
  Reads the `"after"` field of a request: `{:ok, nil}` when there is none,
  `{:ok, map}` for a map of strings and integers (integers are read as their
  text), `{:error, :invalid_cursor}` for anything else.
  """
  @spec from_params(map()) :: {:ok, %{String.t() => String.t()} | nil} | {:error, :invalid_cursor}
  def from_params(params) do
    case params["after"] do
      nil ->
        {:ok, nil}

      %{} = values when map_size(values) in 1..32 ->
        normalize(values)

      _other ->
        {:error, :invalid_cursor}
    end
  end

  defp normalize(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn
      {col, value}, {:ok, acc} when is_binary(col) and is_integer(value) ->
        {:cont, {:ok, Map.put(acc, col, Integer.to_string(value))}}

      {col, value}, {:ok, acc} when is_binary(col) and is_binary(value) ->
        if byte_size(value) <= @max_value_bytes and String.valid?(value) and
             not String.contains?(value, "\0"),
           do: {:cont, {:ok, Map.put(acc, col, value)}},
           else: {:halt, {:error, :invalid_cursor}}

      _pair, _acc ->
        {:halt, {:error, :invalid_cursor}}
    end)
  end

  @doc """
  The condition for the rows strictly after `values` in the order of `key`,
  with its bind values numbered from `$(offset + 1)`. `quote_ident` quotes a
  column name.

  `{:error, :invalid_cursor}` when `values` does not name exactly the key's
  columns or a value does not read as its column's type;
  `{:error, :unsupported_key_type}` for a key no cursor continues from.
  """
  @spec where(key(), %{String.t() => String.t()}, non_neg_integer(), (String.t() -> String.t())) ::
          {:ok, String.t(), [String.t()]} | {:error, :invalid_cursor | :unsupported_key_type}
  def where(key, values, offset, quote_ident) when is_map(values) do
    cond do
      not supported?(key) ->
        {:error, :unsupported_key_type}

      Enum.sort(Map.keys(values)) != Enum.sort(Enum.map(key, &elem(&1, 0))) ->
        {:error, :invalid_cursor}

      not Enum.all?(key, fn {col, type} -> valid_value?(type, values[col]) end) ->
        {:error, :invalid_cursor}

      true ->
        columns = Enum.map_join(key, ", ", fn {col, _type} -> quote_ident.(col) end)

        placeholders =
          key
          |> Enum.with_index(offset + 1)
          |> Enum.map_join(", ", fn {{_col, type}, idx} -> "$#{idx}::text::#{@casts[type]}" end)

        {:ok, "(#{columns}) > (#{placeholders})",
         Enum.map(key, fn {col, _type} -> values[col] end)}
    end
  end

  @doc """
  The cursor that continues after `row`, a map of column name to the value
  as Postgrex returned it: `{:ok, map}`, or `:error` when the key has no
  cursor or the row lacks a key value.
  """
  @spec next_after(key(), map()) :: {:ok, %{String.t() => String.t()}} | :error
  def next_after(key, row) when is_map(row) do
    if supported?(key), do: key_texts(key, row), else: :error
  end

  defp key_texts(key, row) do
    Enum.reduce_while(key, {:ok, %{}}, fn {col, type}, {:ok, acc} ->
      case to_text(type, Map.get(row, col)) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, col, text)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp to_text("uuid", <<_::128>> = bytes), do: Ecto.UUID.load(bytes)
  defp to_text(_type, value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp to_text(_type, %Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
  defp to_text(_type, %Date{} = value), do: {:ok, Date.to_iso8601(value)}
  defp to_text(_type, %NaiveDateTime{} = value), do: {:ok, NaiveDateTime.to_iso8601(value)}
  defp to_text(_type, %DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp to_text(type, value) when is_binary(value) and type in ["text", "character varying"] do
    if byte_size(value) <= @max_value_bytes and String.valid?(value) and
         not String.contains?(value, "\0"),
       do: {:ok, value},
       else: :error
  end

  defp to_text(_type, _value), do: :error

  # A value that does not read as its column's type would fail the query;
  # it is refused here instead, as a bad request.
  defp valid_value?(_type, value) when not is_binary(value), do: false

  defp valid_value?("uuid", value),
    do: byte_size(value) == 36 and match?({:ok, _}, Ecto.UUID.cast(value))

  defp valid_value?(type, value) when type in ["smallint", "integer", "bigint"] do
    case Integer.parse(value) do
      {n, ""} -> n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807
      _ -> false
    end
  end

  defp valid_value?("numeric", value),
    do: match?({%Decimal{coef: coef}, ""} when is_integer(coef), Decimal.parse(value))

  defp valid_value?("date", value), do: match?({:ok, _}, Date.from_iso8601(value))

  defp valid_value?("timestamp without time zone", value),
    do: match?({:ok, _}, NaiveDateTime.from_iso8601(value))

  defp valid_value?("timestamp with time zone", value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_value?(type, _value) when type in ["text", "character varying"], do: true
  defp valid_value?(_type, _value), do: false
end
