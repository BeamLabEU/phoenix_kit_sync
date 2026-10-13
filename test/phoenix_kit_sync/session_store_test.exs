defmodule PhoenixKitSync.SessionStoreTest do
  use ExUnit.Case

  alias PhoenixKitSync.SessionStore

  setup_all do
    # Ensure the global SessionStore is running
    case SessionStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    # Clean up any sessions from previous tests
    for session <- SessionStore.list_active() do
      SessionStore.delete(session.code)
    end

    :ok
  end

  defp make_session(overrides \\ %{}) do
    Map.merge(
      %{
        code: "TEST#{:rand.uniform(9999) |> Integer.to_string() |> String.pad_leading(4, "0")}",
        direction: :receive,
        status: :pending,
        owner_pid: self(),
        created_at: DateTime.utc_now(),
        connected_at: nil
      },
      overrides
    )
  end

  describe "create/1 and get/1" do
    test "creates and retrieves a session" do
      session = make_session()
      assert :ok = SessionStore.create(session)
      assert {:ok, retrieved} = SessionStore.get(session.code)
      assert retrieved.code == session.code
      assert retrieved.direction == :receive
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = SessionStore.get("NONEXIST")
    end

    test "rejects duplicate codes" do
      session = make_session()
      assert :ok = SessionStore.create(session)
      assert {:error, :already_exists} = SessionStore.create(session)
    end
  end

  describe "update/2" do
    test "updates an existing session" do
      session = make_session()
      :ok = SessionStore.create(session)

      updated = %{session | status: :connected}
      assert :ok = SessionStore.update(session.code, updated)
      assert {:ok, retrieved} = SessionStore.get(session.code)
      assert retrieved.status == :connected
    end
  end

  describe "claim/2" do
    @later_states [
      %{status: :completed},
      %{status: :failed},
      %{status: :pending},
      %{status: :pending, connected_at: nil},
      %{channel_pid: nil}
    ]

    test "a code is claimed once" do
      session = make_session()
      :ok = SessionStore.create(session)

      assert {:ok, %{status: :connected}} = SessionStore.claim(session.code, DateTime.utc_now())
      assert {:error, :already_used} = SessionStore.claim(session.code, DateTime.utc_now())
    end

    for {updates, index} <- Enum.with_index(@later_states) do
      test "stays claimed after merge(#{inspect(updates)}) (case #{index})" do
        session = make_session()
        :ok = SessionStore.create(session)
        assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())

        assert {:ok, _} = SessionStore.merge(session.code, unquote(Macro.escape(updates)))
        assert {:error, :already_used} = SessionStore.claim(session.code, DateTime.utc_now())
      end

      test "stays claimed after update/2 writes #{inspect(updates)} (case #{index})" do
        session = make_session()
        :ok = SessionStore.create(session)
        assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())

        # The whole map as it was before the claim, as a stale writer holds it.
        assert :ok =
                 SessionStore.update(
                   session.code,
                   Map.merge(session, unquote(Macro.escape(updates)))
                 )

        assert {:error, :already_used} = SessionStore.claim(session.code, DateTime.utc_now())
      end
    end

    test "update_session/2 with a final status does not free the code" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      assert {:ok, _} = PhoenixKitSync.validate_code(session.code)

      for status <- [:completed, :failed, :pending] do
        assert {:ok, _} = PhoenixKitSync.update_session(session.code, %{status: status})
        assert {:error, :already_used} = PhoenixKitSync.validate_code(session.code)
      end
    end

    test "a code created again after its session was deleted starts unclaimed" do
      session = make_session()
      :ok = SessionStore.create(session)
      assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())

      :ok = SessionStore.delete(session.code)
      assert {:error, :not_found} = SessionStore.claim(session.code, DateTime.utc_now())

      :ok = SessionStore.create(session)
      assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())
    end

    test "the claim goes when the owner does" do
      owner = spawn(fn -> receive(do: (:stop -> :ok)) end)
      session = make_session(%{owner_pid: owner})
      :ok = SessionStore.create(session)
      assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())

      ref = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}
      # The store handles its own DOWN before this call.
      assert {:error, :not_found} = SessionStore.claim(session.code, DateTime.utc_now())

      :ok = SessionStore.create(%{session | owner_pid: self()})
      assert {:ok, _} = SessionStore.claim(session.code, DateTime.utc_now())
    end
  end

  describe "delete/1" do
    test "deletes a session" do
      session = make_session()
      :ok = SessionStore.create(session)
      assert :ok = SessionStore.delete(session.code)
      assert {:error, :not_found} = SessionStore.get(session.code)
    end

    test "no-op for non-existent code" do
      assert :ok = SessionStore.delete("NONEXIST")
    end
  end

  describe "count_active/0" do
    test "counts sessions" do
      :ok = SessionStore.create(make_session(%{code: "CNT00001"}))
      :ok = SessionStore.create(make_session(%{code: "CNT00002"}))
      assert SessionStore.count_active() == 2
    end
  end

  describe "process monitoring" do
    test "cleans up session when owner process dies" do
      session = make_session()

      # Spawn an owner process
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      session = %{session | owner_pid: owner}
      :ok = SessionStore.create(session)

      # Verify session exists
      assert {:ok, _} = SessionStore.get(session.code)

      # Kill the owner
      send(owner, :stop)
      # Give the monitor time to fire
      Process.sleep(50)

      # Session should be cleaned up
      assert {:error, :not_found} = SessionStore.get(session.code)
    end
  end

  # ===========================================
  # LIST_ACTIVE TESTS
  # ===========================================

  describe "list_active/0" do
    test "returns empty list when no sessions" do
      assert SessionStore.list_active() == []
    end

    test "returns all sessions" do
      s1 = make_session(%{code: "LIST0001"})
      s2 = make_session(%{code: "LIST0002"})
      s3 = make_session(%{code: "LIST0003"})

      :ok = SessionStore.create(s1)
      :ok = SessionStore.create(s2)
      :ok = SessionStore.create(s3)

      active = SessionStore.list_active()
      codes = Enum.map(active, & &1.code)

      assert "LIST0001" in codes
      assert "LIST0002" in codes
      assert "LIST0003" in codes
    end

    test "returns sessions sorted by created_at descending" do
      now = DateTime.utc_now()
      early = DateTime.add(now, -120, :second)
      mid = DateTime.add(now, -60, :second)
      late = now

      s1 = make_session(%{code: "SORT0001", created_at: early})
      s2 = make_session(%{code: "SORT0002", created_at: late})
      s3 = make_session(%{code: "SORT0003", created_at: mid})

      :ok = SessionStore.create(s1)
      :ok = SessionStore.create(s2)
      :ok = SessionStore.create(s3)

      sorted_codes =
        SessionStore.list_active()
        |> Enum.filter(&String.starts_with?(&1.code, "SORT"))
        |> Enum.map(& &1.code)

      assert sorted_codes == ["SORT0002", "SORT0003", "SORT0001"]
    end
  end

  # ===========================================
  # CONCURRENT ACCESS TESTS
  # ===========================================

  describe "concurrent access" do
    test "multiple creates from different processes don't interfere" do
      me = self()

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            code = "CONC#{String.pad_leading(Integer.to_string(i), 4, "0")}"
            session = make_session(%{code: code, owner_pid: me})
            SessionStore.create(session)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      for i <- 1..10 do
        code = "CONC#{String.pad_leading(Integer.to_string(i), 4, "0")}"
        assert {:ok, _} = SessionStore.get(code)
      end
    end

    test "create and get from different processes" do
      session = make_session(%{code: "CROSSPROC1"})
      :ok = SessionStore.create(session)

      result =
        Task.async(fn ->
          SessionStore.get("CROSSPROC1")
        end)
        |> Task.await()

      assert {:ok, retrieved} = result
      assert retrieved.code == "CROSSPROC1"
    end
  end

  # ===========================================
  # UPDATE EDGE CASES
  # ===========================================

  describe "update/2 edge cases" do
    test "returns error for non-existent code" do
      assert {:error, :not_found} = SessionStore.update("NOPE0000", %{code: "NOPE0000"})
    end
  end
end
