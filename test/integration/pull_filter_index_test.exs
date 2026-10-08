defmodule PhoenixKitSync.Integration.PullFilterIndexTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.PullFilter

  # A filter compares in the key's own type so the key's index serves it;
  # a cast on the column (pk::text) would scan the table. Sequential scans
  # are switched off for the transaction, so the plan shows whether the
  # condition can go to the index.

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp plan(table, filter, type) do
    {:ok, where, binds} = PullFilter.where(filter, ~s["k"], type)
    repo().query!("SET LOCAL enable_seqscan = off")
    %{rows: rows} = repo().query!(~s[EXPLAIN SELECT * FROM "#{table}" WHERE #{where}], binds)
    Enum.map_join(rows, "\n", &hd/1)
  end

  for {type, column_type, filter} <- [
        {"integer", "integer", {:ids, [1, 2]}},
        {"smallint", "smallint", {:range, 1, 40_000}},
        {"bigint", "bigint", {:ids, [1]}},
        {"uuid", "uuid", {:ids, ["0192e0a4-5a6b-7c8d-9e0f-a1b2c3d4e5f6"]}},
        {"text", "text", {:ids, ["a", 1]}},
        {"character varying", "varchar(20)", {:ids, ["a"]}}
      ] do
    test "a #{column_type} key is filtered through its index" do
      table = "pfi_#{String.replace(unquote(column_type), ~r/\W/, "_")}"
      repo().query!(~s[CREATE TABLE "#{table}" (k #{unquote(column_type)} PRIMARY KEY)])

      # "Index Cond": the condition itself goes to the index. A cast on the
      # column would leave only a full index pass with a Filter.
      assert plan(table, unquote(Macro.escape(filter)), unquote(type)) =~ "Index Cond"
    end
  end
end
