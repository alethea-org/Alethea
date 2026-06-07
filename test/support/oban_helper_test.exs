defmodule Alethea.Test.ObanHelperTest do
  use Alethea.DataCase, async: false

  import Alethea.Test.ObanHelper

  describe "run_job/2" do
    test "executes worker inline with args map" do
      assert :ok = run_job(Alethea.Test.ExampleWorker, %{"id" => 1, "value" => "test"})
    end

    test "executes worker inline with opts" do
      assert :ok = run_job(Alethea.Test.ExampleWorker, %{"id" => 2}, max_attempts: 3)
    end
  end
end

# Helper worker for testing
defmodule Alethea.Test.ExampleWorker do
  use Oban.Worker

  @impl true
  def perform(%Oban.Job{args: %{"fail" => true}}) do
    {:error, "Intentional failure for testing"}
  end

  def perform(%Oban.Job{}) do
    :ok
  end
end
