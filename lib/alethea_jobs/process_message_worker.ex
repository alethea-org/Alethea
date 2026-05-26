defmodule AletheaJobs.ProcessMessageWorker do
  @moduledoc """
  Worker principal para procesar mensajes entrantes de WhatsApp.
  Maneja el onboarding (consentimiento) y deriva al pipeline clínico.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  alias Alethea.{Accounts, Clinical}
  alias Alethea.WhatsApp.ConsentCache
  alias Alethea.Encryption.PatientVault

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
  def perform(%Oban.Job{args: %{"from" => phone, "text" => text} = args}) do
    whatsapp_message_id = args["whatsapp_message_id"]

    case Accounts.lookup_patient_by_phone(phone) do
      {:ok, patient} ->
        process_patient_message(patient, phone, text, whatsapp_message_id)

      {:error, :not_found} ->
        # No registramos nada, solo informamos
        whatsapp_client().send_message(phone, @unregistered_message)
        :ok
    end
  end

  defp process_patient_message(patient, phone, text, whatsapp_message_id) do
    cond do
      patient.terms_accepted ->
        execute_clinical_pipeline(patient, phone, text, whatsapp_message_id)

      String.upcase(String.trim(text)) == "ACEPTO" ->
        case Accounts.update_patient_terms(patient, true) do
          {:ok, _updated_patient} ->
            whatsapp_client().send_message(phone, @welcome_message)
            :ok

          {:error, changeset} ->
            Logger.error("Error al actualizar términos: #{inspect(changeset)}")
            {:error, :database_error}
        end

      true ->
        # El paciente no ha aceptado y no dijo "ACEPTO"
        if ConsentCache.in_progress?(phone) do
          Logger.debug("Consentimiento ya en progreso para #{phone}, ignorando mensaje.")
          :ok
        else
          ConsentCache.mark_in_progress(phone)
          whatsapp_client().send_message(phone, @terms_message)
          :ok
        end
    end
  end

  defp execute_clinical_pipeline(patient, phone, text, whatsapp_message_id) do
    # 1. Obtener llaves
    professional = Accounts.get_professional!(patient.professional_id)
    {:ok, kek} = Accounts.load_professional_kek(professional)
    {:ok, dek} = Accounts.load_patient_dek(patient, kek)

    # 2. Guardar mensaje inbound (spontaneous)
    {:ok, inbound_msg} =
      Clinical.save_message(patient, text, dek, "inbound", "spontaneous", whatsapp_message_id)

    # 3. Construir contexto (historial de mensajes)
    patient_context = build_conversation_context(patient.id, dek)

    # 4. Inferencia IA
    chain_result =
      phi_worker().process(%{
        message_id: inbound_msg.id,
        raw_content: text,
        patient_context: patient_context
      })

    # 5. Guardar respuesta IA (elicited)
    ai_response = chain_result.ai_response

    {:ok, _outbound_msg} =
      Clinical.save_message(patient, ai_response, dek, "outbound", "elicited")

    # 6. Guardar diagnóstico/análisis
    {:ok, _diagnosis} = Clinical.save_ai_diagnosis(inbound_msg.id, chain_result)

    # 7. Enviar por WhatsApp
    whatsapp_client().send_message(phone, ai_response)
    :ok
  end

  defp build_conversation_context(patient_id, dek) do
    Clinical.list_recent_messages(patient_id, 10)
    |> Enum.map_join("\n", fn msg ->
      {:ok, text} = PatientVault.decrypt(msg.encrypted_content, dek)
      label = if msg.direction == "inbound", do: "Paciente", else: "Alethea"
      "#{label}: #{text}"
    end)
  end

  defp whatsapp_client do
    Application.get_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)
  end

  defp phi_worker do
    Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)
  end
end
