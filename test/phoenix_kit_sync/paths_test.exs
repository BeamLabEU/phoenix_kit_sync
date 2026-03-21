defmodule PhoenixKitSync.PathsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Paths

  # These functions return paths via PhoenixKit.Utils.Routes
  # Test that they return strings containing expected path segments

  describe "index/0" do
    test "returns a string containing sync path" do
      path = Paths.index()
      assert is_binary(path)
      assert path =~ "sync"
    end
  end

  describe "connections/0" do
    test "returns a string containing sync/connections path" do
      path = Paths.connections()
      assert is_binary(path)
      assert path =~ "sync/connections"
    end
  end

  describe "history/0" do
    test "returns a string containing sync/history path" do
      path = Paths.history()
      assert is_binary(path)
      assert path =~ "sync/history"
    end
  end
end
