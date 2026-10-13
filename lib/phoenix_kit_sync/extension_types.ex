defmodule PhoenixKitSync.ExtensionTypes do
  @moduledoc """
  The wire form of the column types Postgrex returns as a struct of its
  own: how the exporters write one and how the importers read it back, for
  the REST and the WebSocket paths alike.

  Carried, as text the importer turns back into the same value:

  | Column type | Struct | Text |
  |-------------|--------|------|
  | `interval` | `Postgrex.Interval` | `"14 mons 3 days 14706000007 microseconds"` |
  | `inet`, `cidr` | `Postgrex.INET` | `"10.0.0.1"`, `"10.0.0.0/8"`, `"::1/128"` |
  | `macaddr` | `Postgrex.MACADDR` | `"08:00:2b:01:02:03"` |

  An interval's three parts are written as Postgres stores them (months,
  days and microseconds are not folded into one another), in whole
  numbers, so nothing is rounded.

  Not carried: ranges and multiranges, the geometric types (`point`,
  `line`, `lseg`, `box`, `path`, `polygon`, `circle`) and `tsvector` (a
  list of `Postgrex.Lexeme`, marked by its first element). The
  exporter writes `%{"__phoenix_kit_unsupported__" => "Postgrex.Range"}` in
  place of such a value, and the importer fails that record, naming the
  type, instead of storing text that only looks like the value.
  """

  import Bitwise

  @unsupported "__phoenix_kit_unsupported__"
  @types ["interval", "inet", "cidr", "macaddr"]

  @doc "The column types `parse/2` reads."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  Writes a struct Postgrex returned for a column value: its text for a type
  this module carries, the unsupported marker for any other struct.
  """
  @spec serialize(struct()) :: String.t() | %{String.t() => String.t()}
  def serialize(%Postgrex.Interval{months: months, days: days, secs: secs, microsecs: micro}),
    do: "#{months} mons #{days} days #{secs * 1_000_000 + micro} microseconds"

  def serialize(%Postgrex.INET{address: address, netmask: netmask})
      when is_tuple(address) and (is_nil(netmask) or is_integer(netmask)) do
    text = address |> :inet.ntoa() |> to_string()
    if netmask, do: "#{text}/#{netmask}", else: text
  end

  def serialize(%Postgrex.MACADDR{address: {_, _, _, _, _, _} = address}) do
    address
    |> Tuple.to_list()
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  def serialize(%module{}), do: %{@unsupported => inspect(module)}

  @doc """
  Reads the text `serialize/1` wrote for a column of `type` back into the
  struct Postgrex binds: `{:ok, struct}`, or `:error` for text that is not
  that type's.
  """
  @spec parse(String.t(), String.t()) :: {:ok, struct()} | :error
  def parse("interval", text) when is_binary(text) do
    case Regex.run(~r/\A(-?\d{1,10}) mons (-?\d{1,10}) days (-?\d{1,19}) microseconds\z/, text) do
      [_all, months, days, micro] ->
        micro = String.to_integer(micro)

        {:ok,
         %Postgrex.Interval{
           months: String.to_integer(months),
           days: String.to_integer(days),
           secs: div(micro, 1_000_000),
           microsecs: rem(micro, 1_000_000)
         }}

      nil ->
        :error
    end
  end

  def parse(type, text) when type in ["inet", "cidr"] and is_binary(text) do
    {address, netmask} =
      case String.split(text, "/", parts: 2) do
        [address, netmask] -> {address, Integer.parse(netmask)}
        [address] -> {address, nil}
      end

    with true <- byte_size(text) <= 64,
         {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)),
         {:ok, netmask} <- netmask(netmask, tuple_size(tuple) <<< 3) do
      {:ok, %Postgrex.INET{address: tuple, netmask: netmask}}
    else
      _not_an_address -> :error
    end
  end

  def parse("macaddr", text) when is_binary(text) do
    with [_, _, _, _, _, _] = parts <- String.split(text, ":"),
         true <- Enum.all?(parts, &(byte_size(&1) == 2)),
         bytes = Enum.map(parts, &Integer.parse(&1, 16)),
         true <- Enum.all?(bytes, &match?({_byte, ""}, &1)) do
      {:ok, %Postgrex.MACADDR{address: bytes |> Enum.map(&elem(&1, 0)) |> List.to_tuple()}}
    else
      _not_a_mac -> :error
    end
  end

  def parse(_type, _text), do: :error

  # An IPv4 tuple has 4 elements and 32 bits, an IPv6 one 8 and 128: the
  # address tuple's size times 8 for the first, times 16 for the second.
  defp netmask(nil, _bits), do: {:ok, nil}

  defp netmask({netmask, ""}, bits) when netmask >= 0 do
    max = if bits == 32, do: 32, else: 128
    if netmask <= max, do: {:ok, netmask}, else: :error
  end

  defp netmask(_other, _bits), do: :error

  @doc """
  The type named by an unsupported marker, or nil for any other value.
  """
  @spec unsupported(term()) :: String.t() | nil
  def unsupported(%{@unsupported => type} = marker)
      when map_size(marker) == 1 and is_binary(type),
      do: type

  def unsupported(_value), do: nil
end
