defmodule PhoenixKitSync.PullFilterTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.PullFilter

  # The record filter of a precise pull, checked the same way on both ends.

  describe "body/1 (receiver side)" do
    test "no option means no filter" do
      assert {:ok, %{}} = PullFilter.body(conflict_strategy: "skip")
    end

    test "ids go as given" do
      assert {:ok, %{"ids" => [1, "0192"]}} = PullFilter.body(ids: [1, "0192"])
    end

    test "a range leaves an open bound out" do
      assert {:ok, %{"id_start" => 3}} = PullFilter.body(id_range: {3, nil})
      assert {:ok, %{"id_start" => 3, "id_end" => 9}} = PullFilter.body(id_range: {3, 9})
    end

    test "an empty, oversized or malformed filter is refused" do
      for opts <- [
            [ids: []],
            [ids: nil],
            [ids: Enum.to_list(1..1001)],
            [ids: ["a\0b"]],
            [id_range: {nil, nil}],
            [id_range: {"abc", nil}],
            [id_range: {1, 2}, ids: [1]]
          ] do
        assert {:error, :invalid_filter} = PullFilter.body(opts), inspect(opts)
      end
    end
  end

  describe "from_params/1 (sender side)" do
    test "no filter fields" do
      assert {:ok, nil} = PullFilter.from_params(%{"table_name" => "t"})
    end

    test "ids and ranges" do
      assert {:ok, {:ids, [1, "abc"]}} = PullFilter.from_params(%{"ids" => [1, "abc"]})
      assert {:ok, {:range, 2, nil}} = PullFilter.from_params(%{"id_start" => 2})
      assert {:ok, {:ids, ids}} = PullFilter.from_params(%{"ids" => Enum.to_list(1..1000)})
      assert length(ids) == 1000
    end

    test "malformed filters are refused" do
      for params <- [
            %{"ids" => Enum.to_list(1..1001)},
            %{"ids" => []},
            %{"ids" => "1,2"},
            %{"ids" => [%{"a" => 1}]},
            %{"ids" => [[1]]},
            %{"ids" => [1.5]},
            %{"ids" => [String.duplicate("x", 256)]},
            %{"ids" => ["a\0b"]},
            %{"ids" => [9_223_372_036_854_775_808]},
            %{"id_start" => "2"},
            %{"id_end" => 9_223_372_036_854_775_808},
            %{"id_start" => -9_223_372_036_854_775_809},
            %{"ids" => [1], "id_start" => 1}
          ] do
        assert {:error, :invalid_filter} = PullFilter.from_params(params), inspect(params)
      end
    end
  end

  describe "where/3" do
    test "compares in the key's own type" do
      assert {:ok, ~s|"id" = ANY($1::bigint[])|, [[1, 2]]} =
               PullFilter.where({:ids, [1, 2]}, ~s["id"], "integer")

      uuid = "0192e0a4-5a6b-7c8d-9e0f-a1b2c3d4e5f6"

      assert {:ok, ~s|"uuid" = ANY($1::uuid[])|, [[bytes]]} =
               PullFilter.where({:ids, [String.upcase(uuid)]}, ~s["uuid"], "uuid")

      assert bytes == Ecto.UUID.dump!(uuid)

      assert {:ok, ~s|"code" = ANY($1::text[])|, [["7", "a"]]} =
               PullFilter.where({:ids, [7, "a"]}, ~s["code"], "character varying")

      assert {:ok, ~s["id" >= $1::bigint AND "id" <= $2::bigint], [2, 5]} =
               PullFilter.where({:range, 2, 5}, ~s["id"], "smallint")
    end

    test "values that do not fit the key are refused" do
      assert {:error, :invalid_filter} = PullFilter.where({:ids, ["x"]}, ~s["id"], "bigint")
      assert {:error, :invalid_filter} = PullFilter.where({:ids, ["nope"]}, ~s["u"], "uuid")

      # 16 characters would pass Ecto.UUID.cast/1 as raw bytes.
      assert {:error, :invalid_filter} =
               PullFilter.where({:ids, ["abcdefghijklmnop"]}, ~s["u"], "uuid")

      assert {:error, :invalid_filter} = PullFilter.where({:range, 1, 2}, ~s["u"], "uuid")
      assert {:error, :invalid_filter} = PullFilter.where({:range, 1, nil}, ~s["c"], "text")
    end

    test "other key types take no filter" do
      assert {:error, :unsupported_key_type} =
               PullFilter.where({:ids, ["2026-01-01"]}, ~s["d"], "date")
    end
  end
end
