defmodule PhoenixKitSync.DataImporter do
  @moduledoc """
  Handles import of records from remote sender with conflict resolution.

  This module is responsible for importing records received from a sender
  into the local database, handling primary key conflicts according to
  the configured strategy.

  ## Conflict Strategies

  - `:skip` - Skip import if record with same primary key exists (default)
  - `:overwrite` - Replace existing record with imported data
  - `:merge` - Merge imported data with existing record (keeps existing values where new is nil)
  - `:append` - Always insert as new record with auto-generated ID (ignores source primary key)

  ## Usage

      # Import a batch of records with a strategy
      {:ok, result} = DataImporter.import_records("users", records, :skip)

      # Result structure:
      %{
        created: 5,
        updated: 2,
        skipped: 3,
        errors: []
      }
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKitSync.SchemaInspector

  require Logger

  @type conflict_strategy :: :skip | :overwrite | :merge | :append
  @type import_result :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: list()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Imports a batch of records into the specified table.

  ## Parameters

  - `table` - The table name to import into
  - `records` - List of record maps from the sender
  - `strategy` - Conflict resolution strategy (`:skip`, `:overwrite`, `:merge`, `:append`)

  ## Returns

  - `{:ok, result}` with counts and any errors
  - `{:error, reason}` if import fails completely
  """
  @spec import_records(String.t(), list(map()), conflict_strategy()) ::
          {:ok, import_result()} | {:error, term()}
  def import_records(table, records, strategy \\ :skip) when is_list(records) do
    repo = RepoHelper.repo()

    with {:ok, schema} <- SchemaInspector.get_schema(table),
         primary_keys <- get_primary_keys(schema) do
      # Values are read back into their column's type once, here: every
      # lookup and write below binds the prepared values.
      column_types = column_types(schema)
      records = Enum.map(records, &prepare_record(&1, column_types))

      # Single pre-pass: fetch every existing row this batch might conflict
      # with in one SELECT, keyed by PK value, instead of running one SELECT
      # per record. For :append there's nothing to look up. Composite PKs
      # fall back to the empty map and per-record find_existing — the
      # composite case is rare across phoenix_kit schemas (all use a single
      # UUIDv7 PK) and would need a row-constructor IN clause to batch.
      existing_by_pk = prefetch_existing(repo, table, records, primary_keys, strategy)

      result =
        Enum.reduce(records, %{created: 0, updated: 0, skipped: 0, errors: []}, fn record, acc ->
          accumulate_import_result(
            acc,
            repo,
            table,
            record,
            primary_keys,
            strategy,
            existing_by_pk
          )
        end)

      {:ok, %{result | errors: Enum.reverse(result.errors)}}
    end
  end

  @doc """
  Imports records for multiple tables in a single operation.

  ## Parameters

  - `table_records` - Map of table name to records list
  - `strategies` - Map of table name to conflict strategy

  ## Returns

  - `{:ok, %{table_name => result}}`
  """
  @spec import_multiple(map(), map()) :: {:ok, map()} | {:error, term()}
  def import_multiple(table_records, strategies \\ %{}) when is_map(table_records) do
    results =
      table_records
      |> Enum.map(fn {table, records} ->
        strategy = Map.get(strategies, table, :skip)

        case import_records(table, records, strategy) do
          {:ok, result} -> {table, result}
          {:error, reason} -> {table, %{created: 0, updated: 0, skipped: 0, errors: [reason]}}
        end
      end)
      |> Map.new()

    {:ok, results}
  end

  # ============================================================================
  # Single Record Import
  # ============================================================================

  defp accumulate_import_result(acc, repo, table, record, primary_keys, strategy, existing_by_pk) do
    case import_single_record(repo, table, record, primary_keys, strategy, existing_by_pk) do
      {:ok, :created} -> %{acc | created: acc.created + 1}
      {:ok, :updated} -> %{acc | updated: acc.updated + 1}
      {:ok, :skipped} -> %{acc | skipped: acc.skipped + 1}
      {:error, reason} -> %{acc | errors: [{record, reason} | acc.errors]}
    end
  end

  defp import_single_record(repo, table, record, primary_keys, :append, _existing) do
    # For append strategy: strip primary keys and insert as new record
    record_without_pk = Map.drop(record, primary_keys)
    insert_record(repo, table, record_without_pk)
  rescue
    e ->
      Logger.warning("DataImporter: Error importing record - #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  defp import_single_record(repo, table, record, primary_keys, strategy, existing_by_pk) do
    # Fast path: lookup in the pre-fetched map. Composite PKs (or any record
    # whose PKs weren't fetchable) fall through to a per-record
    # find_existing call so correctness isn't traded for the optimisation.
    case lookup_existing(record, primary_keys, existing_by_pk) do
      {:hit, nil} ->
        insert_record(repo, table, record)

      {:hit, existing} ->
        handle_conflict(repo, table, existing, record, primary_keys, strategy)

      :miss ->
        case find_existing(repo, table, record, primary_keys) do
          nil -> insert_record(repo, table, record)
          existing -> handle_conflict(repo, table, existing, record, primary_keys, strategy)
        end
    end
  rescue
    e ->
      Logger.warning("DataImporter: Error importing record - #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  # Batch-fetches every row whose PK matches any record in the incoming
  # batch, returning `%{pk_value => row}`. Only the single-PK case is
  # batched — multi-column PKs need a row-constructor IN clause which isn't
  # worth the complexity until a phoenix_kit table actually uses a
  # composite PK. Returns an empty map for :append (no conflict check
  # needed) and for any case that can't safely batch; the caller falls back
  # to the per-record `find_existing/4` path.
  defp prefetch_existing(_repo, _table, _records, _primary_keys, :append), do: %{}
  defp prefetch_existing(_repo, _table, _records, [], _strategy), do: %{}
  defp prefetch_existing(_repo, _table, _records, [_, _ | _], _strategy), do: %{}

  defp prefetch_existing(repo, table, records, [pk], _strategy) do
    pk_values = extract_pk_values(records, pk)

    with :ok <- validate_identifiers([table, pk]),
         false <- pk_values == [] do
      sql = ~s[SELECT * FROM "#{table}" WHERE "#{pk}" = ANY($1)]
      run_prefetch_query(repo, sql, pk_values, pk)
    else
      _ -> %{}
    end
  end

  defp extract_pk_values(records, pk) do
    records
    |> Enum.map(fn record -> Map.get(record, pk) || Map.get(record, safe_atom(pk)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp run_prefetch_query(repo, sql, pk_values, pk) do
    case repo.query(sql, [pk_values]) do
      {:ok, %{rows: rows, columns: columns}} -> index_rows_by_pk(rows, columns, pk)
      _ -> %{}
    end
  end

  defp index_rows_by_pk(rows, columns, pk) do
    Map.new(rows, fn row ->
      row_map = Enum.zip(columns, row) |> Map.new()
      {Map.get(row_map, pk), row_map}
    end)
  end

  # Returns {:hit, existing_or_nil} when the prefetch covers this record
  # (single-PK case with a resolvable PK value), or :miss when the caller
  # should fall back to find_existing/4 (composite PK or missing PK value).
  defp lookup_existing(_record, [], _existing_by_pk), do: :miss
  defp lookup_existing(_record, [_, _ | _], _existing_by_pk), do: :miss

  defp lookup_existing(record, [pk], existing_by_pk) do
    case Map.get(record, pk) || Map.get(record, safe_atom(pk)) do
      nil -> :miss
      pk_value -> {:hit, Map.get(existing_by_pk, pk_value)}
    end
  end

  defp find_existing(_repo, _table, _record, []) do
    # No primary keys, can't find existing record
    nil
  end

  defp find_existing(repo, table, record, primary_keys) do
    pk_pairs =
      primary_keys
      |> Enum.map(fn pk ->
        {pk, Map.get(record, pk) || Map.get(record, safe_atom(pk))}
      end)
      |> Enum.reject(fn {_pk, v} -> is_nil(v) end)

    with :ok <- validate_identifiers([table | primary_keys]),
         false <- Enum.empty?(pk_pairs) do
      {conditions, binds} =
        pk_pairs
        |> Enum.with_index(1)
        |> Enum.map(fn {{pk, v}, idx} -> {~s["#{pk}" = $#{idx}], v} end)
        |> Enum.unzip()

      sql = ~s[SELECT * FROM "#{table}" WHERE #{Enum.join(conditions, " AND ")} LIMIT 1]

      case repo.query(sql, binds) do
        {:ok, %{rows: [row], columns: columns}} ->
          Enum.zip(columns, row) |> Map.new()

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp insert_record(repo, table, record) do
    columns = Map.keys(record)

    with :ok <- validate_identifiers([table | columns]) do
      binds = Enum.map(columns, fn c -> Map.get(record, c) end)
      quoted_cols = Enum.map_join(columns, ", ", fn c -> ~s["#{c}"] end)
      placeholders = 1..length(binds) |> Enum.map_join(", ", fn i -> "$#{i}" end)

      sql = ~s[INSERT INTO "#{table}" (#{quoted_cols}) VALUES (#{placeholders})]

      case repo.query(sql, binds) do
        {:ok, _} -> {:ok, :created}
        {:error, error} -> {:error, format_error(error)}
      end
    end
  end

  defp handle_conflict(_repo, _table, _existing, _record, _primary_keys, :skip) do
    {:ok, :skipped}
  end

  defp handle_conflict(repo, table, existing, record, primary_keys, :overwrite) do
    update_record(repo, table, record, primary_keys, existing)
  end

  defp handle_conflict(repo, table, existing, record, primary_keys, :merge) do
    # Merge: keep existing values where new is nil
    merged =
      record
      |> Enum.reduce(existing, fn {key, value}, acc ->
        key_str = to_string(key)

        if is_nil(value) do
          acc
        else
          Map.put(acc, key_str, value)
        end
      end)

    update_record(repo, table, merged, primary_keys, existing)
  end

  defp update_record(repo, table, record, primary_keys, existing) do
    case Enum.reject(record, fn {key, _} -> to_string(key) in primary_keys end) do
      [] -> {:ok, :skipped}
      set_pairs -> do_update_record(repo, table, set_pairs, primary_keys, existing)
    end
  end

  defp do_update_record(repo, table, set_pairs, primary_keys, existing) do
    set_columns = Enum.map(set_pairs, fn {k, _v} -> to_string(k) end)

    with :ok <- validate_identifiers([table | primary_keys ++ set_columns]) do
      set_values = Enum.map(set_pairs, fn {_k, v} -> v end)
      offset = length(set_values)

      set_clause =
        set_columns
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {col, idx} -> ~s["#{col}" = $#{idx}] end)

      where_clause =
        primary_keys
        |> Enum.with_index(offset + 1)
        |> Enum.map_join(" AND ", fn {pk, idx} -> ~s["#{pk}" = $#{idx}] end)

      where_binds = Enum.map(primary_keys, fn pk -> Map.get(existing, pk) end)

      sql = ~s[UPDATE "#{table}" SET #{set_clause} WHERE #{where_clause}]

      case repo.query(sql, set_values ++ where_binds) do
        {:ok, _} -> {:ok, :updated}
        {:error, error} -> {:error, format_error(error)}
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_primary_keys(%{primary_key: pks}) when is_list(pks), do: pks

  defp get_primary_keys(schema) when is_map(schema) do
    columns = Map.get(schema, :columns) || Map.get(schema, "columns") || []

    columns
    |> Enum.filter(fn col ->
      Map.get(col, :primary_key) || Map.get(col, "is_primary_key") || Map.get(col, "primary_key")
    end)
    |> Enum.map(fn col -> Map.get(col, :name) || Map.get(col, "name") end)
  end

  defp column_types(schema) do
    schema
    |> Map.get(:columns, [])
    |> Map.new(fn col -> {Map.get(col, :name), Map.get(col, :type)} end)
  end

  defp prepare_record(record, column_types) when is_map(record) do
    Map.new(record, fn {key, value} ->
      key = to_string(key)
      {key, prepare_typed_value(value, Map.get(column_types, key))}
    end)
  end

  defp prepare_record(record, _column_types), do: record

  # Values the JSON form cannot carry natively, read back by column type.
  # Bytes travel base64-wrapped (as the HTTP API sends them); a uuid as its
  # text, or wrapped by older senders; a numeric as a string. The wrapper is
  # only read in the columns it is written for: in a json column the same
  # shape is just an object.
  defp prepare_typed_value(%{"__phoenix_kit_binary__" => encoded} = value, type)
       when type in ["bytea", "uuid"] and is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> bytes
      :error -> value
    end
  end

  # Postgrex encodes a json value itself: an object, an array or a scalar
  # goes as the decoded term, never as its JSON text.
  defp prepare_typed_value(value, type) when type in ["json", "jsonb"], do: value

  # Bytes that happen to be UTF-8 travel as plain text; they are still
  # bytes, not a date or a time.
  defp prepare_typed_value(value, "bytea") when is_binary(value), do: value

  defp prepare_typed_value(value, "uuid") when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.dump(value) do
      {:ok, bytes} -> bytes
      :error -> value
    end
  end

  defp prepare_typed_value(value, type)
       when is_binary(value) and type in ["numeric", "decimal"] do
    case parse_numeric(value) do
      {:ok, decimal} -> decimal
      :error -> value
    end
  end

  defp prepare_typed_value(value, _type), do: prepare_value(value)

  # A numeric's text is digits with an optional fraction. Decimal.parse/1
  # stops at decimal128's 34 significant digits, far short of what a numeric
  # column holds, so this form is built directly. It is bounded by what the
  # exporter can write instead: Decimal renders at most 6178 digits, and a
  # numeric's scale stops at 16383. A longer value can only come from a peer
  # building it by hand, and Postgrex's encoding grows with the square of
  # its length, so it fails its record. Anything else (an exponent, NaN,
  # Infinity) is short and goes to Decimal.parse/1.
  @numeric_text ~r/\A([+-]?)(\d+)(?:\.(\d+))?\z/
  @numeric_max_digits 6178
  @numeric_max_scale 16_383

  defp parse_numeric(value) do
    case Regex.run(@numeric_text, value, capture: :all_but_first) do
      [sign, int | frac] -> build_numeric(sign, int, List.first(frac, ""))
      nil -> parse_decimal(value)
    end
  end

  defp build_numeric(sign, int, frac) do
    digits = String.trim_leading(int <> frac, "0")
    exp = -byte_size(frac)

    if byte_size(digits) + max(exp, 0) <= @numeric_max_digits and exp >= -@numeric_max_scale do
      sign = if sign == "-", do: -1, else: 1
      {:ok, Decimal.new(sign, coef(digits), exp)}
    else
      :error
    end
  end

  defp coef(""), do: 0
  defp coef(digits), do: String.to_integer(digits)

  defp parse_decimal(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp prepare_value(%{"__type__" => "datetime", "value" => value}) do
    # Handle serialized datetime
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "date", "value" => value}) do
    # Handle serialized date
    case Date.from_iso8601(value) do
      {:ok, d} -> d
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "time", "value" => value}) do
    # Handle serialized time
    case Time.from_iso8601(value) do
      {:ok, t} -> t
      _ -> value
    end
  end

  defp prepare_value(%{"__type__" => "decimal", "value" => value}) do
    # Handle serialized decimal
    Decimal.new(value)
  end

  # Parse ISO8601 datetime strings (from exporter)
  defp prepare_value(value) when is_binary(value) do
    parse_iso_datetime(value) || parse_iso_date(value) || parse_iso_time(value) || value
  end

  # Pass structs (DateTime, Decimal, etc.) through so Postgrex can bind them natively
  defp prepare_value(%_{} = value), do: value

  # Encode plain maps and lists as JSON strings for jsonb/text columns
  defp prepare_value(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> value
    end
  end

  defp prepare_value(value), do: value

  # DateTime with timezone (e.g., "2025-12-15T18:56:59.387453Z")
  @datetime_pattern ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/
  defp parse_iso_datetime(value) do
    if Regex.match?(@datetime_pattern, value) do
      case DateTime.from_iso8601(value) do
        {:ok, dt, _offset} -> dt
        _ -> try_naive_datetime(value)
      end
    end
  end

  defp try_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end

  # Date only (e.g., "2025-12-15")
  @date_pattern ~r/^\d{4}-\d{2}-\d{2}$/
  defp parse_iso_date(value) do
    if Regex.match?(@date_pattern, value) do
      case Date.from_iso8601(value) do
        {:ok, d} -> d
        _ -> nil
      end
    end
  end

  # Time only (e.g., "18:56:59" or "18:56:59.387453")
  @time_pattern ~r/^\d{2}:\d{2}:\d{2}(\.\d+)?$/
  defp parse_iso_time(value) do
    if Regex.match?(@time_pattern, value) do
      case Time.from_iso8601(value) do
        {:ok, t} -> t
        _ -> nil
      end
    end
  end

  # All dynamic SQL identifiers (table + column names) are validated against
  # SchemaInspector.valid_identifier?/1 before being interpolated with quotes.
  # Values are always passed as parameterized binds via repo.query(sql, binds)
  # — never interpolated into the SQL string — so the query body never carries
  # attacker-controlled data.
  defp validate_identifiers(names) do
    if Enum.all?(names, &SchemaInspector.valid_identifier?/1) do
      :ok
    else
      {:error, :invalid_identifier}
    end
  end

  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp format_error(%{postgres: %{message: message}}) do
    message
  end

  defp format_error(%{message: message}) do
    message
  end

  defp format_error(error) when is_binary(error) do
    error
  end

  defp format_error(error) do
    inspect(error)
  end
end
