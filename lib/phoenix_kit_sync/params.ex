defmodule PhoenixKitSync.Params do
  @moduledoc """
  Reads numbers that arrive from outside — a URL parameter, a LiveView
  event, a peer's WebSocket payload, an API request — where anything can
  turn up.
  """

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

  defp whole_number(n) when is_integer(n), do: {:ok, n}

  defp whole_number(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp whole_number(_value), do: :error
end
