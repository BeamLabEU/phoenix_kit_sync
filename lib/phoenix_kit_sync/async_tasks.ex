defmodule PhoenixKitSync.AsyncTasks do
  @moduledoc """
  Spawn async tasks that need to outlive the calling process.

  Used by the admin LiveViews to fire HTTP notifications after a DB
  commit (status change, delete, etc.) — the DB transaction has already
  succeeded, so the remote site should learn about it even if the admin
  closes the tab. `Task.start_link/1` is wrong for this case because it
  cancels the task when the LV dies, and a bare `Task.start/1` runs with
  no supervision: failures aren't logged and tasks accumulate on a hung
  HTTP timeout.

  `notify_remote_async/1` routes through `PhoenixKit.TaskSupervisor` (a
  named `Task.Supervisor` started by core `phoenix_kit`'s supervision
  tree) with `restart: :temporary`. When that supervisor is not running
  (a stripped-down test environment; core starts it in every host) the
  task is started linked to the caller instead, so it is still owned by a
  process and still runs: it then ends with its caller rather than
  outliving it, and the fallback is logged.
  """

  require Logger

  @doc """
  Spawns `fun` as a fire-and-forget task supervised by
  `PhoenixKit.TaskSupervisor`, or linked to the caller when that
  supervisor is not running. Returns `{:ok, pid}`.
  """
  @spec notify_remote_async((-> term())) :: {:ok, pid()} | {:error, term()}
  def notify_remote_async(fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fun, restart: :temporary)
  catch
    :exit, _ ->
      Logger.warning(
        "[Sync.AsyncTasks] PhoenixKit.TaskSupervisor is not running; task linked to its caller"
      )

      Task.start_link(fun)
  end
end
