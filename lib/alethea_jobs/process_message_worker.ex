defmodule AletheaJobs.ProcessMessageWorker do
  @moduledoc """
  Worker principal para procesar mensajes entrantes de WhatsApp.
  Maneja el onboarding (consentimiento) y deriva al pipeline clínico.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  alias Alethea.Accounts
  alias Alethea.WhatsApp.ConsentCache

  @client Application.compile_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)

  require Logger

  @terms_message """
  Hola, soy Alethea, tu diario clínico inteligente.

  Para poder ayudarte y que tu terapeuta pueda ver tu progreso, necesito que aceptes los términos de uso y el tratamiento de tus datos personales (que están cifrados y protegidos).

  Responde "ACEPTO" para continuar.
  """

  @welcome_message """
  ¡Gracias! He activado tu diario. A partir de ahora puedes escribirme cuando lo necesites.
  Todo lo que me cuentes será analizado para tu próxima sesión.
  """

  @unregistered_message "Hola. No reconozco este número en nuestro sistema clínico. Si eres un paciente, por favor contacta a tu terapeuta para que te registre."

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"from" => phone, "text" => text}}) do
    case Accounts.lookup_patient_by_phone(phone) do
      {:ok, patient} ->
        process_patient_message(patient, phone, text)

      {:error, :not_found} ->
        # No registramos nada, solo informamos
        @client.send_message(phone, @unregistered_message)
        :ok
    end
  end

  defp process_patient_message(patient, phone, text) do
    cond do
      patient.terms_accepted ->
        # TODO: Derivar al pipeline clínico (Issue 003)
        Logger.info("Paciente #{patient.id} envió mensaje clínico: #{text}")
        :ok

      String.upcase(String.trim(text)) == "ACEPTO" ->
        case Accounts.update_patient_terms(patient, true) do
          {:ok, _updated_patient} ->
            @client.send_message(phone, @welcome_message)
            :ok

          {:error, changeset} ->
            Logger.error("Error al actualizar términos: #{inspect(changeset)}")
            {:error, :database_error}
        end

      true ->
        # El paciente no ha aceptado y no dijo "ACEPTO"
        # Verificamos si ya le enviamos los términos recientemente
        if ConsentCache.in_progress?(phone) do
          Logger.debug("Consentimiento ya en progreso para #{phone}, ignorando mensaje.")
          :ok
        else
          ConsentCache.mark_in_progress(phone)
          @client.send_message(phone, @terms_message)
          :ok
        end
    end
  end
end
