defmodule AletheaJobs.SessionReminderWorker do
  use Oban.Worker,
    queue: :sessions,
    max_attempts: 3,
    unique: [fields: [:args], period: 23 * 3600]

  alias Alethea.{Accounts, Clinical}
  alias Alethea.Encryption.PatientVault

  require Logger

  defp whatsapp_client,
    do: Application.get_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)

  @reminder_message """
  Hola, te recordamos que mañana tienes una sesión programada con tu terapeuta.
  Si necesitas reprogramar, comunícate con tu terapeuta.
  """

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"patient_id" => patient_id}}) do
    patient = Accounts.get_patient!(patient_id)

    with {:ok, phone} <- decrypt_phone(patient),
         {:ok, _response} <- whatsapp_client().send_message(phone, @reminder_message) do
      Accounts.log_action(%{
        professional_id: patient.professional_id,
        action: "SESSION_REMINDER_SENT",
        resource_type: "Patient",
        resource_id: patient.id,
        details: %{scheduled_at: patient.session_time}
      })

      :ok
    else
      {:error, reason} ->
        Accounts.log_action(%{
          professional_id: patient.professional_id,
          action: "SESSION_REMINDER_FAILED",
          resource_type: "Patient",
          resource_id: patient.id,
          details: %{reason: inspect(reason)}
        })

        Logger.error("SessionReminderWorker failed for patient #{patient_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decrypt_phone(patient) do
    with {:ok, dek} <- Clinical.patient_dek(patient) do
      PatientVault.decrypt(patient.encrypted_whatsapp_number, dek)
    end
  end
end
