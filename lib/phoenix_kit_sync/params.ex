defmodule PhoenixKitSync.Params do
  @moduledoc """
  Reads numbers that arrive from outside — a URL parameter, a LiveView
  event, a peer's WebSocket payload, an API request — where anything can
  turn up.
  """

  # The largest offset taken from outside. No synced table comes near it,
  # and it keeps `offset + limit` far inside the database's bigint.
  @max_offset 1_000_000_000

  @doc "The largest record offset accepted from a request or a peer."
  @spec max_offset() :: pos_integer()
  def max_offset, do: @max_offset

  @doc """
  Returns `value` as an integer within `min..max`.

  A whole number (an integer, or a string holding only one, surrounding
  spaces aside) is clamped to the bounds; anything else — text, a
  fraction, `"5abc"`, nil — gives `default`. Clamping also keeps a huge
  page or offset from overflowing the database's bigint.
  """
  @spec bounded_int(term(), integer(), integer(), integer()) :: integer()
  def bounded_int(value, default, min, max) when min <= max do
    case whole_number(value) do
      {:ok, n} -> n |> Kernel.max(min) |> Kernel.min(max)
      :error -> default
    end
  end

  @doc """
  Returns `value` as a page number from 1 to `max`.

  Anything that is not a whole number in that range gives page 1, a page
  above `max` included: a page that far out is a broken link, not a request
  for the last page. The caller clamps a page past its own last page.
  """
  @spec page(term(), pos_integer()) :: pos_integer()
  def page(value, max) when is_integer(max) and max >= 1 do
    case whole_number(value) do
      {:ok, n} when n >= 1 and n <= max -> n
      _ -> 1
    end
  end

  defp whole_number(n) when is_integer(n), do: {:ok, n}

  defp whole_number(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp whole_number(_value), do: :error
end
