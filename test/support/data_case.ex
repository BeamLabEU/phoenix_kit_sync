defmodule PhoenixKitSync.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses PhoenixKitSync.Test.Repo with SQL Sandbox for isolation.
  Tests using this case are tagged :integration and will be
  excluded when the database is unavailable.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitSync.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitSync.ChangesetHelpers
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
