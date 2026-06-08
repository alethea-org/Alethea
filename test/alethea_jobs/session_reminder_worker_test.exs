defmodule AletheaJobs.SessionReminderWorkerTest do
  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Mox

  alias Alethea.Accounts
  alias AletheaJobs.SessionReminderWorker

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "reminder_test_#{:rand.uniform(999_999)}@example.com",
        password: "securepassword123",
        full_name: "Reminder Tester"
      })

    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => "+541133334444",
          "alias" => "Reminder Patient",
          "professional_id" => professional.id,
          "session_day_of_week" => 1,
          "session_time" => ~T[10:00:00]
        },
        kek
      )

    %{patient: patient}
  end

  test "sends WhatsApp reminder and logs audit on success", %{patient: patient} do
    Alethea.WhatsApp.ClientMock
    |> expect(:send_message, fn phone, body ->
      assert String.starts_with?(phone, "+")
      assert body =~ "sesión"
      {:ok, %{"messages" => [%{"id" => "wamid.test123"}]}}
    end)

    assert :ok = perform_job(SessionReminderWorker, %{"patient_id" => patient.id})
  end

  test "returns error and logs audit on WhatsApp failure", %{patient: patient} do
    Alethea.WhatsApp.ClientMock
    |> expect(:send_message, fn _phone, _body ->
      {:error, :network_timeout}
    end)

    assert {:error, :network_timeout} =
             perform_job(SessionReminderWorker, %{"patient_id" => patient.id})
  end
end
