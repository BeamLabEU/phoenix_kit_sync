defmodule PhoenixKitSync.AsyncTasksTest do
  use ExUnit.Case, async: false

  alias PhoenixKitSync.AsyncTasks

  # Pinning test for the supervised vs linked task distinction. Before
  # the fix, every async notification was bare `Task.start/1` — orphan
  # processes could pile up on a hung HTTP timeout. The fix routes
  # through `PhoenixKit.TaskSupervisor` with `restart: :temporary`. The
  # test starts a task that blocks on `receive`, then verifies the task
  # PID shows up in `Task.Supervisor.children/1` — proving it's
  # registered with the supervisor and not a bare unsupervised process.

  test "notify_remote_async/1 spawns a child of PhoenixKit.TaskSupervisor" do
    parent = self()
    ref = make_ref()

    {:ok, task_pid} =
      AsyncTasks.notify_remote_async(fn ->
        send(parent, {:started, ref, self()})

        receive do
          {:done, ^ref} -> :ok
        after
          2_000 -> :timeout
        end
      end)

    assert_receive {:started, ^ref, ^task_pid}, 1_000

    children = Task.Supervisor.children(PhoenixKit.TaskSupervisor)

    assert task_pid in children,
           "expected task #{inspect(task_pid)} to be a child of PhoenixKit.TaskSupervisor; " <>
             "children=#{inspect(children)}"

    # Cleanup: unblock the task so it terminates.
    send(task_pid, {:done, ref})
  end

  test "notify_remote_async/1 returns {:ok, pid} on the supervised path" do
    {:ok, pid} = AsyncTasks.notify_remote_async(fn -> :ok end)
    assert is_pid(pid)
  end

  describe "without PhoenixKit.TaskSupervisor" do
    setup do
      supervisor = Process.whereis(PhoenixKit.TaskSupervisor)
      Process.unregister(PhoenixKit.TaskSupervisor)
      on_exit(fn -> Process.register(supervisor, PhoenixKit.TaskSupervisor) end)
      :ok
    end

    test "the task still runs, linked to its caller rather than orphaned" do
      parent = self()

      caller =
        spawn(fn ->
          {:ok, task} =
            AsyncTasks.notify_remote_async(fn ->
              send(parent, {:task, self()})
              Process.sleep(:infinity)
            end)

          send(parent, {:started, task})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, task}, 1_000
      assert_receive {:task, ^task}, 1_000

      # Linked: the task is owned by its caller and ends with it. A bare
      # Task.start/1 would leave it running with no owner.
      assert {:links, links} = Process.info(task, :links)
      assert caller in links

      ref = Process.monitor(task)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 1_000
    end
  end
end
