defmodule PhoenixKitSync.ParamsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Params

  # Numbers from a URL, an event or a peer's payload: anything that is not
  # a whole number falls back to the default, and the result always lies
  # within the bounds.

  test "a whole number within the bounds is kept" do
    assert Params.bounded_int("3", 1, 1, 100) == 3
    assert Params.bounded_int(" 3 ", 1, 1, 100) == 3
    assert Params.bounded_int(3, 1, 1, 100) == 3
  end

  test "anything else falls back to the default" do
    for value <- ["abc", "", "5abc", "1.5", nil, 1.5, %{}, ["1"]] do
      assert Params.bounded_int(value, 7, 1, 100) == 7, inspect(value)
    end
  end

  test "values outside the bounds are clamped" do
    assert Params.bounded_int("0", 1, 1, 100) == 1
    assert Params.bounded_int("-1", 1, 1, 100) == 1
    assert Params.bounded_int(-5, 0, 0, 100) == 0
    assert Params.bounded_int("101", 1, 1, 100) == 100
    assert Params.bounded_int("99999999999999999999999", 1, 1, 100) == 100
  end
end
