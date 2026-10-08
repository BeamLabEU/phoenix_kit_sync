defmodule PhoenixKitSync.Web.ConnectionsLive.FormatBytesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ConnectionsLive

  # `size_bytes` in the sync table picker comes from the sender's
  # list-tables reply, so it can hold anything JSON can.

  test "numbers render with a unit" do
    assert ConnectionsLive.format_bytes(nil) == "0 B"
    assert ConnectionsLive.format_bytes(0) == "0 B"
    assert ConnectionsLive.format_bytes(512) == "512 B"
    assert ConnectionsLive.format_bytes(2048) == "2.0 KB"
    assert ConnectionsLive.format_bytes(5_242_880) == "5.0 MB"
    assert ConnectionsLive.format_bytes(3_221_225_472) == "3.0 GB"
  end

  test "anything that is not a number renders as a dash" do
    for value <- ["1024", "big", %{}, [1], true] do
      assert ConnectionsLive.format_bytes(value) == "—", inspect(value)
    end
  end
end
