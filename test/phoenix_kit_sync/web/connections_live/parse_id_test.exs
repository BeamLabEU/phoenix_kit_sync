defmodule PhoenixKitSync.Web.ConnectionsLive.ParseIdTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ConnectionsLive

  # An ID typed into Precise Transfer is sent as an integer only when that
  # is exactly what was typed: the form cannot know the key's type, and a
  # text key "007" is not the row 7.

  test "a whole integer becomes an integer" do
    assert ConnectionsLive.parse_id("7") == 7
    assert ConnectionsLive.parse_id("-12") == -12
    assert ConnectionsLive.parse_id("0") == 0
  end

  test "zero-padded and signed forms stay as typed" do
    assert ConnectionsLive.parse_id("007") == "007"
    assert ConnectionsLive.parse_id("+5") == "+5"
    assert ConnectionsLive.parse_id("-0") == "-0"
  end

  test "uuids and text keys stay as typed" do
    assert ConnectionsLive.parse_id("0192abcd-0000-7000-8000-000000000000") ==
             "0192abcd-0000-7000-8000-000000000000"

    assert ConnectionsLive.parse_id("sku-12") == "sku-12"
    assert ConnectionsLive.parse_id("12abc") == "12abc"
  end
end
