defmodule PhoenixKitSync.SyncableTable do
  @moduledoc """
  A real, plain table for tests that export, list or pull one: a uuid
  primary key with a database default, one required text column, empty in
  the test database.

  The module's own tables cannot stand in for it: they hold the connection
  credentials and are never synced (`SchemaInspector.excluded_table?/1`).
  """

  @table "phoenix_kit_media_folders"

  @doc "The table's name."
  @spec name() :: String.t()
  def name, do: @table

  @doc "Inserts one row and returns its uuid as text."
  @spec insert!(String.t() | nil) :: String.t()
  def insert!(name \\ nil) do
    name = name || "Row #{System.unique_integer([:positive])}"

    %{rows: [[uuid]]} =
      PhoenixKit.RepoHelper.repo().query!(
        ~s[INSERT INTO "#{@table}" (name) VALUES ($1) RETURNING uuid::text],
        [name]
      )

    uuid
  end
end
