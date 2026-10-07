defmodule PhoenixKitSync.PullFilter do
  @moduledoc """
  The record filter of a precise pull, shared by both ends of the protocol.

  On the wire a filter is either `"ids"` (a list of key values) or an
  integer range `"id_start"` / `"id_end"` (an open bound left out). Both
  `pull-data` and `table-records` take it.

    * `body/1` — receiver side: builds the request fields from the
      `:ids` / `:id_range` options, refusing an empty or oversized filter
      before anything is requested.
    * `from_params/1` — sender side: validates the request fields into
      `nil`, `{:ids, values}` or `{:range, start, end}`.
    * `where/3` — sender side: the SQL condition on the table's
      single-column key. Values are compared in the key's own type, so the
      key's index is used: integers as `bigint` (the integer types compare
      across widths through the index), a uuid key takes uuid values, a
      text or varchar key takes text. A range needs an integer key; other
      key types do not take a filter.

  Every value is a bind parameter; the key name arrives quoted.
  """

  @max_ids 1000
  @max_id_bytes 255
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @type t :: nil | {:ids, [integer() | String.t()]} | {:range, integer() | nil, integer() | nil}

  @doc "The most ids one filtered request may carry."
  @spec max_ids() :: pos_integer()
  def max_ids, do: @max_ids

  @doc """
  Request fields for the `:ids` / `:id_range` options, or
  `{:error, :invalid_filter}`: an `:ids` list that is empty, too long or
  holds an unusable value, or a range without either bound. No option
  means no filter (`%{}`).
  """
  @spec body(keyword()) :: {:ok, map()} | {:error, :invalid_filter}
  def body(opts) do
    case {Keyword.fetch(opts, :ids), Keyword.get(opts, :id_range)} do
      {:error, nil} ->
        {:ok, %{}}

      {{:ok, ids}, nil} ->
        if valid_ids?(ids), do: {:ok, %{"ids" => ids}}, else: {:error, :invalid_filter}

      {:error, {id_start, id_end}} ->
        range_body(id_start, id_end)

      _both_or_malformed ->
        {:error, :invalid_filter}
    end
  end

  defp range_body(nil, nil), do: {:error, :invalid_filter}

  defp range_body(id_start, id_end) do
    if Enum.all?([id_start, id_end], &(is_nil(&1) or int64?(&1))) do
      {:ok, Map.reject(%{"id_start" => id_start, "id_end" => id_end}, &is_nil(elem(&1, 1)))}
    else
      {:error, :invalid_filter}
    end
  end

  @doc """
  Validates the filter fields of a request: `{:ok, nil}` when there are
  none.
  """
  @spec from_params(map()) :: {:ok, t()} | {:error, :invalid_filter}
  def from_params(params) do
    case {params["ids"], params["id_start"], params["id_end"]} do
      {nil, nil, nil} ->
        {:ok, nil}

      {ids, nil, nil} ->
        if valid_ids?(ids), do: {:ok, {:ids, ids}}, else: {:error, :invalid_filter}

      {nil, id_start, id_end} ->
        if Enum.all?([id_start, id_end], &(is_nil(&1) or int64?(&1))),
          do: {:ok, {:range, id_start, id_end}},
          else: {:error, :invalid_filter}

      _ids_and_range ->
        {:error, :invalid_filter}
    end
  end

  defp valid_ids?(ids) when is_list(ids) and ids != [],
    do: length(ids) <= @max_ids and Enum.all?(ids, &valid_id?/1)

  defp valid_ids?(_ids), do: false

  defp valid_id?(id) when is_integer(id), do: int64?(id)

  defp valid_id?(id) when is_binary(id) do
    byte_size(id) in 1..@max_id_bytes and String.valid?(id) and not String.contains?(id, "\0")
  end

  defp valid_id?(_id), do: false

  defp int64?(n), do: is_integer(n) and n >= @int64_min and n <= @int64_max

  @integer_types ~w(smallint integer bigint)
  @text_types ["text", "character varying"]

  @doc """
  The condition for `filter` on the quoted key `pk` of SQL type `key_type`,
  with its bind values, numbered from `$1`. `{:error, :invalid_filter}`
  when a value does not fit the key (a non-integer id for an integer key,
  a malformed uuid, a range on a non-integer key);
  `{:error, :unsupported_key_type}` for a key type outside
  smallint / integer / bigint / uuid / text / varchar.
  """
  @spec where(t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), list()} | {:error, :invalid_filter | :unsupported_key_type}
  def where({:ids, ids}, pk, type) when type in @integer_types do
    if Enum.all?(ids, &is_integer/1),
      do: {:ok, "#{pk} = ANY($1::bigint[])", [ids]},
      else: {:error, :invalid_filter}
  end

  def where({:ids, ids}, pk, "uuid") do
    case dump_uuids(ids) do
      {:ok, uuids} -> {:ok, "#{pk} = ANY($1::uuid[])", [uuids]}
      :error -> {:error, :invalid_filter}
    end
  end

  def where({:ids, ids}, pk, type) when type in @text_types,
    do: {:ok, "#{pk} = ANY($1::text[])", [Enum.map(ids, &to_string/1)]}

  def where({:range, id_start, id_end}, pk, type) when type in @integer_types do
    bounds = Enum.reject([{">=", id_start}, {"<=", id_end}], fn {_op, v} -> is_nil(v) end)

    where =
      bounds
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {{op, _v}, idx} -> "#{pk} #{op} $#{idx}::bigint" end)

    {:ok, where, Enum.map(bounds, fn {_op, v} -> v end)}
  end

  def where({:range, _id_start, _id_end}, _pk, type) when type in ["uuid" | @text_types],
    do: {:error, :invalid_filter}

  def where(_filter, _pk, _type), do: {:error, :unsupported_key_type}

  defp dump_uuids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      # Only the 36-character text: Ecto.UUID.cast/1 would also take any
      # 16-byte string as raw bytes.
      with true <- is_binary(id) and byte_size(id) == 36,
           {:ok, uuid} <- Ecto.UUID.cast(id),
           {:ok, bytes} <- Ecto.UUID.dump(uuid) do
        {:cont, {:ok, [bytes | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, bytes} -> {:ok, Enum.reverse(bytes)}
      :error -> :error
    end
  end
end
