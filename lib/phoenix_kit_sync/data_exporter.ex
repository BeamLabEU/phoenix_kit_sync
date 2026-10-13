defmodule PhoenixKitSync.DataExporter do
  @moduledoc """
  Exports data from database tables for DB Sync module.

  Provides functions to fetch records from tables with pagination,
  handle data serialization, and stream large datasets.

  ## Security Considerations

  - Uses parameterized queries to prevent SQL injection
  - Refuses a table, schema or `:order_by` name outside
    `SchemaInspector.valid_identifier?/1` (`{:error, :invalid_table_name}`,
    `{:error, :invalid_column_name}`) before any query, on every function
    here: quoting alone would read a real table named `"customer-data"`
  - Refuses the tables that are never synced
    (`SchemaInspector.excluded_table?/1`, `{:error, :table_excluded}`)
  - Validates table names against actual database tables

  ## Example

      iex> DataExporter.get_count("users")
      {:ok, 150}

      iex> DataExporter.fetch_records("users", offset: 0, limit: 100)
      {:ok, [
        %{"id" => 1, "email" => "user@example.com", ...},
        ...
      ]}
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKitSync.ExtensionTypes
  alias PhoenixKitSync.PullCursor
  alias PhoenixKitSync.SchemaInspector

  @default_limit 100
  @max_limit 1000

  @doc "The most records `fetch_records/2` returns in one call."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Gets the exact count of records in a table.

  ## Options

  - `:schema` - Database schema (default: "public")
  """
  @spec get_count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_count(table_name, opts \\ []) do
    with :ok <- check_names(table_name, opts) do
      if SchemaInspector.excluded_table?(table_name) do
        {:error, :table_excluded}
      else
        do_get_count(table_name, opts)
      end
    end
  end

  # The names a caller hands in, which come from the peer on the socket
  # paths: checked before anything is read.
  defp check_names(table_name, opts) do
    order_by = opts |> Keyword.get(:order_by) |> List.wrap()

    cond do
      not SchemaInspector.valid_identifier?(table_name) ->
        {:error, :invalid_table_name}

      not SchemaInspector.valid_identifier?(Keyword.get(opts, :schema, "public")) ->
        {:error, :invalid_table_name}

      not Enum.all?(order_by, &SchemaInspector.valid_identifier?/1) ->
        {:error, :invalid_column_name}

      true ->
        :ok
    end
  end

  defp do_get_count(table_name, opts) do
    schema = Keyword.get(opts, :schema, "public")

    # Validate table exists first
    if SchemaInspector.table_exists?(table_name, schema: schema) do
      # Use exact count for accuracy
      # For very large tables, consider using estimated count from pg_stat
      query = "SELECT COUNT(*) FROM #{quote_identifier(schema)}.#{quote_identifier(table_name)}"

      case RepoHelper.query(query, []) do
        {:ok, %{rows: [[count]]}} ->
          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :table_not_found}
    end
  end

  @doc """
  Fetches records from a table with pagination.

  Records are returned as maps with string keys matching column names.
  All values are JSON-serializable.

  ## Options

  - `:offset` - Number of records to skip (default: 0)
  - `:limit` - Maximum records to return (default: 100, max: 1000)
  - `:schema` - Database schema (default: "public")
  - `:order_by` - Column(s) to order by (default: primary key)
  - `:after` - A `PhoenixKitSync.PullCursor` position; see `fetch_page/2`

  A table with no primary key (and no `:order_by`) has no order to page in,
  so it is served only when it fits in one page (at most `:limit` rows,
  whatever the `:offset`): a larger one returns `{:error, :no_primary_key}`.
  """
  @spec fetch_records(String.t(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def fetch_records(table_name, opts \\ []) do
    with {:ok, %{records: records}} <- fetch_page(table_name, opts), do: {:ok, records}
  end

  @doc """
  Fetches one page of a table and the position the next page continues
  from.

  Takes the options of `fetch_records/2`. With `:after` (the `next_after`
  of the page before, as `PhoenixKitSync.PullCursor.from_params/1` reads
  it) the page is the rows after that key and `:offset` is ignored, so rows
  inserted or deleted since the page before neither repeat nor hide a row.
  Without it the page is cut by `:offset`, which is what a peer that does
  not send a position gets.

  `next_after` is `nil` for an empty page, for a key no cursor continues
  from and under a custom `:order_by`; the caller then pages by offset.
  `{:error, :invalid_cursor}` when `:after` does not fit the table's key.
  """
  @spec fetch_page(String.t(), keyword()) ::
          {:ok, %{records: [map()], next_after: %{String.t() => String.t()} | nil}}
          | {:error, any()}
  def fetch_page(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)

    # Validate table exists and get schema info
    with :ok <- check_names(table_name, opts),
         {:ok, table_schema} <- SchemaInspector.get_schema(table_name, schema: schema) do
      do_fetch_page(table_name, schema, table_schema, offset, limit, opts)
    else
      {:error, :not_found} ->
        {:error, :table_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports all records from a table as a stream.

  Useful for large tables where loading all records into memory
  is not practical. Returns a stream that yields batches of records, each
  starting after the key the one before ended on (`fetch_page/2`).

  ## Options

  - `:batch_size` - Records per batch (default: 500)
  - `:schema` - Database schema (default: "public")
  """
  @spec stream_records(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, any()}
  def stream_records(table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    batch_size = Keyword.get(opts, :batch_size, 500)

    with :ok <- check_names(table_name, opts),
         {:ok, table_schema} <- SchemaInspector.get_schema(table_name, schema: schema) do
      stream =
        Stream.resource(
          fn -> {0, nil} end,
          fn at ->
            stream_next_batch(table_name, schema, table_schema, at, batch_size, opts)
          end,
          fn _at -> :ok end
        )

      {:ok, stream}
    end
  end

  @doc """
  Serializes the value of an array column, a list as Postgrex returned it,
  by the type of its elements (`ColumnInfo.element_type`).

  Each element follows the rule for a scalar of that type at every depth of
  a multi-dimensional array: a uuid goes as its canonical text, other
  non-UTF-8 bytes wrapped in base64, a date or a number as its text or
  itself. `PhoenixKitSync.DataImporter.prepare_array/2` reads the list back.
  """
  @spec serialize_array(String.t() | nil, list()) :: list()
  def serialize_array(element_type, list) when is_list(list),
    do: serialize_elements(element_type, list)

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  # Pages are cut with LIMIT/OFFSET, which only means something over a fixed
  # order: without one, Postgres is free to return rows in a different
  # order on each query, and a paged read skips some rows and repeats
  # others. A table with no primary key (and no `:order_by`) is refused,
  # unless it fits in one page: then there is nothing to page over and the
  # order does not matter. A position (`:after`) is a place in primary-key
  # order, so it is refused under any other order.
  defp do_fetch_page(table_name, schema, table_schema, offset, limit, opts) do
    source = {table_name, schema, table_schema}

    case {Keyword.get(opts, :order_by), table_schema.primary_key, Keyword.get(opts, :after)} do
      {nil, [], nil} ->
        fetch_single_page(source, offset, limit)

      {nil, [], _after} ->
        {:error, :no_primary_key}

      {nil, primary_key, nil} ->
        fetch_ordered(source, primary_key, primary_key(table_schema), {:offset, offset}, limit)

      {nil, primary_key, %{} = position} ->
        fetch_ordered(source, primary_key, primary_key(table_schema), {:after, position}, limit)

      {[], _primary_key, _after} ->
        {:error, :no_primary_key}

      {order_by, _primary_key, nil} ->
        fetch_ordered(source, order_by, [], {:offset, offset}, limit)

      {_order_by, _primary_key, _after} ->
        {:error, :invalid_cursor}
    end
  end

  # A keyless table is read whole, one row past the limit to tell a table
  # that fits in one page from one that does not; `:offset` only skips rows
  # of that one page, so the page after the last is empty. A table that grows
  # past the limit between two requests is refused on the second.
  defp fetch_single_page(source, offset, limit) do
    with {:ok, %{records: records}} <- fetch_ordered(source, [], [], {:offset, 0}, limit + 1) do
      if length(records) > limit,
        do: {:error, :no_primary_key},
        else: {:ok, %{records: Enum.drop(records, offset), next_after: nil}}
    end
  end

  # The primary key as PullCursor reads it: `{column, type}` in key order.
  defp primary_key(table_schema) do
    types = Map.new(table_schema.columns, &{&1.name, &1.type})
    Enum.map(table_schema.primary_key, &{&1, Map.get(types, &1)})
  end

  defp fetch_ordered({table_name, schema, table_schema}, order_by, key, page, limit) do
    # Build column list for SELECT
    column_list = Enum.map_join(table_schema.columns, ", ", &quote_identifier(&1.name))

    with {:ok, page_clause, binds} <- page_clause(key, page, limit) do
      query = """
      SELECT #{column_list}
      FROM #{quote_identifier(schema)}.#{quote_identifier(table_name)}
      #{page_clause.where}
      #{build_order_clause(order_by)}
      #{page_clause.limit}
      """

      case RepoHelper.query(query, binds) do
        {:ok, %{rows: rows}} ->
          {:ok,
           %{
             records: Enum.map(rows, &row_to_map(table_schema.columns, &1)),
             next_after: next_after(key, table_schema.columns, rows)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp page_clause(_key, {:offset, offset}, limit),
    do: {:ok, %{where: "", limit: "LIMIT $1 OFFSET $2"}, [limit, offset]}

  defp page_clause(key, {:after, position}, limit) do
    case PullCursor.where(key, position, 1, &quote_identifier/1) do
      {:ok, condition, binds} ->
        {:ok, %{where: "WHERE #{condition}", limit: "LIMIT $1"}, [limit | binds]}

      # A key with no cursor never answered a position to send back.
      {:error, _reason} ->
        {:error, :invalid_cursor}
    end
  end

  # Where the page after this one starts: the key of its last row, read
  # from the row as Postgrex returned it.
  defp next_after(_key, _columns, []), do: nil

  defp next_after(key, columns, rows) do
    last = columns |> Enum.map(& &1.name) |> Enum.zip(List.last(rows)) |> Map.new()

    case PullCursor.next_after(key, last) do
      {:ok, position} -> position
      _no_position -> nil
    end
  end

  # The next batch starts after the key the one before ended on, so rows
  # written while the stream is read do not shift it; by offset for a key
  # that has no cursor.
  defp stream_next_batch(table_name, schema, table_schema, {offset, position} = at, size, opts) do
    opts = Keyword.put(opts, :after, position)

    case do_fetch_page(table_name, schema, table_schema, offset, size, opts) do
      {:ok, %{records: []}} ->
        {:halt, at}

      {:ok, %{records: records, next_after: next_after}} ->
        {[records], {offset + length(records), next_after}}

      {:error, _reason} ->
        {:halt, at}
    end
  end

  defp row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {col.name, serialize_column(col, val)} end)
  end

  # An array's elements follow the rule for its element type, at every
  # depth of a multi-dimensional array, so a uuid element goes as text
  # whatever its bytes happen to be.
  defp serialize_column(%{type: "ARRAY", element_type: type}, list) when is_list(list),
    do: serialize_elements(type, list)

  defp serialize_column(%{type: type}, value), do: serialize_typed(type, value)

  defp serialize_elements(type, list) do
    Enum.map(list, fn
      sublist when is_list(sublist) -> serialize_elements(type, sublist)
      value -> serialize_typed(type, value)
    end)
  end

  # Records travel as JSON. Postgrex hands a uuid over as its 16 raw bytes;
  # it goes out as its canonical text, which the importer turns back into
  # bytes for a uuid column.
  defp serialize_typed("uuid", <<_::128>> = bytes), do: Ecto.UUID.load!(bytes)
  defp serialize_typed(_type, value), do: serialize_value(value)

  defp build_order_clause([]), do: ""

  defp build_order_clause(columns) when is_list(columns) do
    order_cols = Enum.map_join(columns, ", ", &quote_identifier/1)
    "ORDER BY #{order_cols}"
  end

  defp build_order_clause(column) when is_binary(column) do
    "ORDER BY #{quote_identifier(column)}"
  end

  # Quote identifier to prevent SQL injection
  # PostgreSQL uses double quotes for identifiers
  defp quote_identifier(name) when is_binary(name) do
    # Escape any double quotes in the identifier
    escaped = String.replace(name, "\"", "\"\"")
    "\"#{escaped}\""
  end

  # Serialize values to JSON-compatible format
  # Struct types must come before the is_map guard (structs are maps)
  defp serialize_value(nil), do: nil
  # Text goes as is. Other bytes (bytea) cannot be JSON: they go wrapped in
  # base64 under the same key the HTTP API uses, so every path carries them
  # the same way.
  defp serialize_value(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: %{"__phoenix_kit_binary__" => Base.encode64(value)}
  end

  defp serialize_value(value) when is_number(value), do: value
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value([%Postgrex.Lexeme{} = lexeme | _]), do: ExtensionTypes.serialize(lexeme)
  defp serialize_value(value) when is_list(value), do: Enum.map(value, &serialize_value/1)

  defp serialize_value(%Date{} = date), do: Date.to_iso8601(date)
  defp serialize_value(%Time{} = time), do: Time.to_iso8601(time)
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp serialize_value(%Decimal{} = decimal), do: Decimal.to_string(decimal)

  # Any other struct is a Postgrex type of its own (an interval, an inet,
  # a range): ExtensionTypes writes the ones that travel and marks the
  # rest, so `inspect/1` text never stands in for a value. Must be before
  # the is_map guard.
  defp serialize_value(%_{} = struct), do: ExtensionTypes.serialize(struct)

  # Plain maps (after struct matchers)
  defp serialize_value(value) when is_map(value), do: serialize_map(value)

  # Fallback for other types
  defp serialize_value(value), do: inspect(value)

  defp serialize_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end
end
