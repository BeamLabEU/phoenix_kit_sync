defmodule PhoenixKitSync.Web.SyncRunLifetimeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Web.ConnectionsLive

  for progress <- [nil, :new_run] do
    test "queued work and late results are ignored with progress #{inspect(progress)}" do
      old_run = make_ref()
      progress = if unquote(progress) == :new_run, do: %{run_ref: make_ref()}, else: nil
      socket = %Phoenix.LiveView.Socket{assigns: %{sync_progress: progress}}
      result = {:ok, %{imported: 1, skipped: 0, errors: 0}}

      messages = [
        {:start_detail_sync, old_run, nil, "rows", %{mode: :all}},
        {:do_pull_table, old_run, ["rows"], 0},
        {:sync_table_complete, old_run, "rows", result},
        {:sync_table_complete, old_run, "rows", result, [], 1, %{}}
      ]

      for message <- messages do
        assert {:noreply, ^socket} = ConnectionsLive.handle_info(message, socket)
      end
    end
  end
end
