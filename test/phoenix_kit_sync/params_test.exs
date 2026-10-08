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

  describe "page/2" do
    test "a whole number from 1 to the cap is kept" do
      assert Params.page("1", 10) == 1
      assert Params.page("10", 10) == 10
      assert Params.page(10_001, 1_000_000) == 10_001
    end

    test "anything else, a page above the cap included, gives page 1" do
      for value <- ["11", "99999999999999999999999", "0", "-3", "abc", "", "5abc", nil, 2.0] do
        assert Params.page(value, 10) == 1, inspect(value)
      end
    end
  end
end
