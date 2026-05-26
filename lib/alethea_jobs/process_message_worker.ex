defmodule AletheaJobs.ProcessMessageWorker do
  @moduledoc """
  Worker principal para procesar mensajes entrantes de WhatsApp.
  Maneja el onboarding (consentimiento) y deriva al pipeline clínico.
  """
  use Oban.Worker, queue: :whatsapp, max_attempts: 3

  alias Alethea.Accounts
  alias Alethea.Alerts.CrisisMonitor
  alias Alethea.Clinical
  alias Alethea.WhatsApp.ConsentCache

  @client Application.compile_env(:alethea, :whatsapp_client, Alethea.WhatsApp.Client)
  @phi_worker Application.compile_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)

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
    whatsapp_message_id = Map.get(args, "whatsapp_message_id")

    case Accounts.lookup_patient_by_phone(phone) do
      {:ok, patient} ->
        process_patient_message(patient, phone, text, whatsapp_message_id)

      {:error, :not_found} ->
        @client.send_message(phone, @unregistered_message)
        :ok
    end
  end

  defp process_patient_message(patient, phone, text, whatsapp_message_id) do
    cond do
      patient.terms_accepted ->
        process_clinical_message(patient, phone, text, whatsapp_message_id)

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

  defp process_clinical_message(patient, phone, text, whatsapp_message_id) do
    crisis_support_message =
      Application.get_env(:alethea, :crisis_support_message, default_crisis_support_message())

    context_limit = Application.get_env(:alethea, Alethea.Clinical, [])[:recent_message_limit] || 10

    case CrisisMonitor.detect(text) do
      :safe ->
        case Clinical.save_message(patient, text, nil, "inbound", "spontaneous", whatsapp_message_id) do
          {:ok, inbound_message} ->
            case Clinical.build_patient_context(patient, context_limit) do
              {:ok, patient_context} ->
                chain_result =
                  @phi_worker.process(%{
                    message_id: inbound_message.id,
                    raw_content: text,
                    patient_context: patient_context
                  })

                with {:ok, _outbound_message} <-
                       Clinical.save_message(patient, chain_result.response, nil, "outbound", "elicited", nil),
                     {:ok, _diagnosis} <- Clinical.save_ai_diagnosis(inbound_message.id, chain_result) do
                  @client.send_message(phone, chain_result.response)
                  :ok
                else
                  {:error, reason} ->
                    Logger.error("Error guardando resultado de IA: #{inspect(reason)}")
                    {:error, reason}
                end

              {:error, reason} ->
                Logger.error("Error construyendo contexto del paciente: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, :duplicate, _inbound_message} ->
            Logger.info("Mensaje duplicado de WhatsApp ya procesado: #{whatsapp_message_id}")
            :ok

          {:error, reason} ->
            Logger.error("Error guardando mensaje clínico: #{inspect(reason)}")
            {:error, reason}
        end

      {:crisis, level, triggers} ->
        case Clinical.save_message(patient, text, nil, "inbound", "spontaneous", whatsapp_message_id) do
          {:ok, inbound_message} ->
            crisis_diagnosis = %{
              response: crisis_support_message,
              model_version: "crisis-bypass",
              extracted_emotions: %{crisis: true, level: level, triggers: triggers}
            }

            with {:ok, _diagnosis} <- Clinical.save_ai_diagnosis(inbound_message.id, crisis_diagnosis),
                 {:ok, _patient} <- Accounts.update_patient(patient, %{urgent_intervention: true}),
                 :ok <-
                   Phoenix.PubSub.broadcast(Alethea.PubSub, "crisis:alerts", {:crisis_detected, patient.id, level, triggers}),
                 {:ok, _send_result} <- @client.send_message(phone, crisis_support_message) do
              :ok
            else
              {:error, reason} ->
                Logger.error("Error en bypass de crisis: #{inspect(reason)}")
                {:error, reason}

              other ->
                Logger.error("Error en bypass de crisis: #{inspect(other)}")
                {:error, other}
            end

          {:error, :duplicate, _inbound_message} ->
            Logger.info("Mensaje duplicado de WhatsApp ya procesado: #{whatsapp_message_id}")
            :ok

          {:error, reason} ->
            Logger.error("Error guardando mensaje inbound en crisis: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp default_crisis_support_message do
    "Entiendo que estás pasando por algo muy difícil. Lo que sientes importa."
  end
end
