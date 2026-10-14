defmodule PhoenixKitSync.RateLimit do
  @moduledoc """
  The per-minute request limit of a connection, on both sides of it.

  **Sender.** `check/1` counts one request against the connection's
  `rate_limit_requests_per_minute` and refuses the request over it with the
  seconds until the minute frees. `PhoenixKitSync.Connections.authorize_request/3`
  calls it, and nothing else does: an entry point is limited because it is
  authorized, not because it remembered to count.

  The counter is core's Hammer backend
  (`PhoenixKit.Users.RateLimiter.Backend`, started by core's supervisor): a
  fixed window on the wall clock, held in ETS per node. A sender that runs on
  several nodes allows the limit on each of them, and a restart empties it.
  A limit of `0` (or `nil`) is no limit.

  **Receiver.** A sender over its limit answers 429 with `Retry-After`
  (seconds), or `"error_code": "rate_limited"` with `"retry_after"` on a
  socket. `next_wait/2` turns what the sender asked for into the wait this
  site is willing to make: the value is the peer's, so it is clamped to
  `max_wait/0`, and the waits of one request together stay within
  `wait_budget/0`. Both are seconds and come from app env:

      config :phoenix_kit_sync,
        rate_limit_max_wait_seconds: 60,
        rate_limit_wait_budget_seconds: 300
  """

  require Logger

  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKitSync.Connection

  @window_ms 60_000
  @default_max_wait 60
  @default_wait_budget 300
  # The wait when a sender says it is over its limit without a readable
  # Retry-After.
  @fallback_wait 5

  @type refusal :: {:error, {:rate_limited, pos_integer()}}

  @doc """
  Counts one request under `connection`.

  Returns `:ok`, or `{:error, {:rate_limited, seconds}}` for a request past
  the connection's limit in the current minute, with the seconds until that
  minute ends.
  """
  @spec check(Connection.t()) :: :ok | refusal()
  def check(%Connection{rate_limit_requests_per_minute: limit, uuid: uuid})
      when is_integer(limit) and limit > 0 and is_binary(uuid) do
    hit(uuid, limit)
  end

  def check(%Connection{}), do: :ok

  @doc """
  Counts one request in `key`'s current window of `window_ms`, allowing
  `limit` of them. `check/1` with the window as an argument.
  """
  @spec hit(String.t(), pos_integer(), pos_integer()) :: :ok | refusal()
  def hit(key, limit, window_ms \\ @window_ms)
      when is_binary(key) and is_integer(limit) and limit > 0 do
    case Backend.hit("sync:connection:" <> key, window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, ceil_seconds(retry_after_ms)}}
    end
  rescue
    # The backend's table belongs to core's supervisor. Without it (a host
    # that starts this module on its own) there is nothing to count in: the
    # request is let through rather than every request refused.
    ArgumentError ->
      Logger.warning("Sync: the rate limiter backend is not running; request not counted")
      :ok
  end

  defp ceil_seconds(ms) when is_integer(ms), do: max(1, div(ms + 999, 1000))

  @doc """
  The seconds to wait before asking a rate-limited sender again.

  `retry_after` is what the sender sent (a header value, a JSON number, or
  nothing) and `waited` the seconds this request has waited already. Returns
  `{:wait, seconds}` with the value clamped between 1 and `max_wait/0`, or
  `:give_up` when that wait would pass `wait_budget/0`.

  A value that is not a whole number of seconds (missing, text, an HTTP
  date) reads as #{@fallback_wait} seconds.
  """
  @spec next_wait(term(), non_neg_integer()) :: {:wait, pos_integer()} | :give_up
  def next_wait(retry_after, waited \\ 0) when is_integer(waited) and waited >= 0 do
    seconds = retry_after |> parse_seconds() |> max(1) |> min(max_wait())

    if waited + seconds > wait_budget(), do: :give_up, else: {:wait, seconds}
  end

  defp parse_seconds(value) when is_integer(value), do: value

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} -> seconds
      _ -> @fallback_wait
    end
  end

  defp parse_seconds(_value), do: @fallback_wait

  @doc "The longest single wait, in seconds (`rate_limit_max_wait_seconds`, default 60)."
  @spec max_wait() :: pos_integer()
  def max_wait, do: positive_env(:rate_limit_max_wait_seconds, @default_max_wait)

  @doc """
  The most one request waits in total, in seconds
  (`rate_limit_wait_budget_seconds`, default 300).
  """
  @spec wait_budget() :: pos_integer()
  def wait_budget, do: positive_env(:rate_limit_wait_budget_seconds, @default_wait_budget)

  defp positive_env(key, default) do
    case Application.get_env(:phoenix_kit_sync, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
