defmodule PhoenixKitSync.Web.ApiController.PullFilterValidatorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ApiController.Validators

  # pull-data takes an optional record filter: a list of key values, or an
  # integer key range. It is checked here, before any SQL is built.

  defp pull(extra), do: Map.merge(%{"auth_token_hash" => "h", "table_name" => "t"}, extra)

  test "no filter keeps the request as it was" do
    assert {:ok, %{filter: nil}} = Validators.validate_pull_data(pull(%{}))
  end

  test "ids become a list of strings" do
    assert {:ok, %{filter: {:ids, ["1", "abc"]}}} =
             Validators.validate_pull_data(pull(%{"ids" => [1, "abc"]}))
  end

  test "an integer range keeps whichever bounds were given" do
    assert {:ok, %{filter: {:range, 2, 9}}} =
             Validators.validate_pull_data(pull(%{"id_start" => 2, "id_end" => 9}))

    assert {:ok, %{filter: {:range, 2, nil}}} =
             Validators.validate_pull_data(pull(%{"id_start" => 2}))
  end

  test "malformed filters are refused" do
    too_many = Enum.to_list(1..1001)
    long = String.duplicate("x", 256)

    for extra <- [
          %{"ids" => too_many},
          %{"ids" => []},
          %{"ids" => "1,2"},
          %{"ids" => [%{"a" => 1}]},
          %{"ids" => [[1]]},
          %{"ids" => [1.5]},
          %{"ids" => [long]},
          %{"id_start" => "2"},
          %{"id_start" => 1, "id_end" => "x"},
          %{"ids" => [1], "id_start" => 1}
        ] do
      assert {:error, :invalid_filter} = Validators.validate_pull_data(pull(extra)),
             "expected #{inspect(extra)} to be refused"
    end
  end

  test "a thousand ids are accepted" do
    assert {:ok, %{filter: {:ids, ids}}} =
             Validators.validate_pull_data(pull(%{"ids" => Enum.to_list(1..1000)}))

    assert length(ids) == 1000
  end
end
