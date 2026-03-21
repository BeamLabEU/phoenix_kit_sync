defmodule PhoenixKitSync.ChangesetHelpers do
  @moduledoc """
  Helpers for testing Ecto changesets.
  """

  @doc """
  Transforms changeset errors into a map of message lists.

      assert {:error, changeset} = create_thing(%{name: ""})
      assert "can't be blank" in errors_on(changeset).name
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
