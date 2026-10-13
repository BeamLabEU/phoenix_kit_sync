defmodule PhoenixKitSync.Web.ApiController.ValidatorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ApiController.Validators

  # table-records answers at most 100 records per request. The cap lives
  # only here: the controller passes the validated limit through as is.

  defp records_limit(limit) do
    {:ok, validated} =
      Validators.validate_records(%{
        "auth_token_hash" => "hash",
        "table_name" => "users",
        "limit" => limit
      })

    validated.limit
  end

  test "a limit up to 100 is kept" do
    assert records_limit("1") == 1
    assert records_limit("100") == 100
    assert records_limit(100) == 100
  end

  test "a limit above 100 is capped at 100" do
    assert records_limit("101") == 100
    assert records_limit("1000") == 100
    assert records_limit(1_000_000) == 100
  end

  # The strategy is the peer's word and lands on the sender's own history
  # row, which only takes these four: any other value would drop that row.
  defp pull_strategy(strategy) do
    {:ok, validated} =
      Validators.validate_pull_data(%{
        "auth_token_hash" => "hash",
        "table_name" => "users",
        "conflict_strategy" => strategy
      })

    validated.conflict_strategy
  end

  test "a pull keeps a known conflict strategy and falls back to skip for any other" do
    for strategy <- ~w(skip overwrite merge append),
        do: assert(pull_strategy(strategy) == strategy)

    for strategy <- ["x", "", "OVERWRITE", nil, 1, %{"a" => 1}],
        do: assert(pull_strategy(strategy) == "skip")
  end
end
