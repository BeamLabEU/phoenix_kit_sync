defmodule PhoenixKitSync.ImportWorkerTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Workers.ImportWorker

  describe "create_job/5" do
    test "builds a valid Oban changeset" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345")
      assert %Ecto.Changeset{} = job
      assert job.valid?
    end

    test "converts atom strategy to string" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :overwrite, "ABC12345")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["strategy"] == "overwrite"
    end

    test "passes through string strategy as-is" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], "merge", "ABC12345")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["strategy"] == "merge"
    end

    test "includes batch_index when provided" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345", batch_index: 3)
      args = Ecto.Changeset.get_change(job, :args)
      assert args["batch_index"] == 3
    end

    test "defaults batch_index to 0" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["batch_index"] == 0
    end

    test "includes schema when provided" do
      schema = %{"columns" => [%{"name" => "id", "type" => "integer"}]}

      job =
        ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345", schema: schema)

      args = Ecto.Changeset.get_change(job, :args)
      assert args["schema"] == schema
    end

    test "excludes schema when nil" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345", schema: nil)
      args = Ecto.Changeset.get_change(job, :args)
      refute Map.has_key?(args, "schema")
    end

    test "excludes schema when not provided" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345")
      args = Ecto.Changeset.get_change(job, :args)
      refute Map.has_key?(args, "schema")
    end

    test "includes table name in args" do
      job = ImportWorker.create_job("posts", [%{"id" => 1}], :skip, "XYZ99999")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["table"] == "posts"
    end

    test "includes records in args" do
      records = [%{"id" => 1, "name" => "Alice"}, %{"id" => 2, "name" => "Bob"}]
      job = ImportWorker.create_job("users", records, :skip, "ABC12345")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["records"] == records
    end

    test "includes session_code in args" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "SESS1234")
      args = Ecto.Changeset.get_change(job, :args)
      assert args["session_code"] == "SESS1234"
    end

    test "uses the sync queue" do
      job = ImportWorker.create_job("users", [%{"id" => 1}], :skip, "ABC12345")
      assert Ecto.Changeset.get_change(job, :queue) == "sync"
    end
  end
end
