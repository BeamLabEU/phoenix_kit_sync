defmodule PhoenixKitSync.Web.ConnectionsLive.SortByDependenciesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ConnectionsLive

  # `sort_by_dependencies/2` orders the selected tables for a pull so a
  # table comes after the tables it references. Each table must appear
  # exactly once: a repeat pulls (and imports) the table twice.

  defp table(name, deps), do: %{name: name, depends_on: deps}

  defp sort(names, tables), do: ConnectionsLive.sort_by_dependencies(names, tables)

  test "a self-referencing table appears once" do
    tables = [table("categories", ["categories"])]

    assert sort(["categories"], tables) == ["categories"]
  end

  test "a self-referencing table still comes after its other dependencies" do
    tables = [
      table("categories", ["categories", "media"]),
      table("media", []),
      table("slugs", ["categories"])
    ]

    assert sort(["slugs", "categories", "media"], tables) == ["media", "categories", "slugs"]
  end

  test "a two-table cycle yields each table once" do
    tables = [table("a", ["b"]), table("b", ["a"])]

    sorted = sort(["a", "b"], tables)
    assert Enum.sort(sorted) == ["a", "b"]
  end

  test "dependencies outside the selection are ignored" do
    tables = [table("posts", ["users"]), table("comments", ["posts", "users"])]

    assert sort(["comments", "posts"], tables) == ["posts", "comments"]
  end
end
