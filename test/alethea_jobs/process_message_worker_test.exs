defmodule AletheaJobs.ProcessMessageWorkerTest do
  use Alethea.DataCase, async: false

  import Mox

  alias AletheaJobs.ProcessMessageWorker
  alias Alethea.Accounts
  alias Alethea.WhatsApp.ConsentCache
  alias Alethea.Repo
  alias Alethea.Clinical.Message

  setup :verify_on_exit!

  setup do
    professional = insert_professional()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    %{professional: professional, kek: kek}
  end

  describe "perform/1" do
    test "cuando el número no está registrado, envía mensaje genérico" do
      phone = "56912345678"
      text = "Hola"

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body =~ "No reconozco este número"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text})
    end

    test "cuando el paciente no ha aceptado términos, envía mensaje de consentimiento" do
      professional = insert_professional()
      _patient = insert_patient(professional, "+56911111111", "alias")

      phone = "+56911111111"
      text = "Hola"

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body =~ "términos de uso"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text})
      assert ConsentCache.in_progress?(phone)
    end

    test "cuando el paciente acepta los términos, actualiza la base de datos y envía bienvenida" do
      professional = insert_professional()
      patient = insert_patient(professional, "+56933333333", "alias")

      phone = "+56933333333"
      text = "ACEPTO"

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body =~ "He activado tu diario"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text})

      updated_patient = Accounts.get_patient!(patient.id)
      assert updated_patient.terms_accepted == true
    end

    test "cuando el paciente ya aceptó términos, ejecuta el pipeline clínico completo y mantiene trazabilidad" do
      professional = insert_professional()
      patient = insert_patient(professional, "+56944444444", "alias")
      {:ok, _patient} = Accounts.update_patient_terms(patient, true)

      phone = "+56944444444"
      text = "Necesito hablar sobre mi ansiedad"
      message_id = "wamid.123"

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{
           message_id: _message_id,
           raw_content: ^text,
           patient_context: _context
         } ->
        %{
          response: "¿Qué sientes exactamente?",
          model_version: "phi-4-mini",
          source_message_id: message_id,
          behavior_type: :elicited
        }
      end)

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body == "¿Qué sientes exactamente?"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text, "whatsapp_message_id" => message_id})

      # Verificamos persistencia de mensajes
      messages = Repo.all(Message) |> Repo.preload(:ai_diagnoses)
      assert length(messages) == 2

      inbound = Enum.find(messages, &(&1.direction == "inbound"))
      outbound = Enum.find(messages, &(&1.direction == "outbound"))

      assert inbound.behavior_type == "spontaneous"
      assert inbound.whatsapp_message_id == message_id
      assert outbound.behavior_type == "elicited"
      assert outbound.encrypted_content != nil

      # Verificamos Diagnosis y su vínculo con el mensaje inbound
      assert length(inbound.ai_diagnoses) == 1
      diagnosis = List.first(inbound.ai_diagnoses)
      assert diagnosis.ai_response == "¿Qué sientes exactamente?"
      assert diagnosis.model_version == "phi-4-mini"
    end

    test "cuando se detecta una crisis, cortocircuita el pipeline y notifica al profesional" do
      professional = insert_professional()
      patient = insert_patient(professional, "+56955555555", "alias")
      {:ok, _patient} = Accounts.update_patient_terms(patient, true)

      phone = "+56955555555"
      crisis_text = "Ya no quiero seguir viviendo, me voy a matar."
      message_id = "wamid.crisis"

      # Suscribirse al PubSub para verificar la alerta
      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")

      # No esperamos que se llame al PhiWorker (bypass)
      # Pero sí al WhatsApp Client con el mensaje de soporte
      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body =~ "estás pasando por algo muy difícil"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => crisis_text, "whatsapp_message_id" => message_id})

      # 1. Verificar que el paciente fue marcado para intervención urgente
      updated_patient = Accounts.get_patient!(patient.id)
      assert updated_patient.urgent_intervention == true

      # 2. Verificar persistencia (Mensaje + Diagnosis con metadata de crisis)
      inbound = Repo.get_by(Message, whatsapp_message_id: message_id) |> Repo.preload(:ai_diagnoses)
      assert inbound
      assert inbound.behavior_type == "spontaneous"
      
      assert length(inbound.ai_diagnoses) == 1
      diagnosis = List.first(inbound.ai_diagnoses)
      assert diagnosis.model_version == "crisis-bypass"
      assert diagnosis.extracted_emotions["crisis"] == true
      assert diagnosis.extracted_emotions["level"] == "immediate"

      # 3. Verificar broadcast por PubSub
      assert_receive {:crisis_detected, %{patient_id: pid, level: :immediate}}
      assert pid == patient.id
    end
  end

  defp perform_job(args) do
    %Oban.Job{args: args}
    |> ProcessMessageWorker.perform()
  end

  defp insert_professional do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "test#{System.unique_integer()}@test.com",
        password: "password12345",
        full_name: "Dr. Test"
      })

    professional
  end

  defp insert_patient(professional, phone, alias_name) do
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{
          "whatsapp_number" => phone,
          "alias" => alias_name,
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end
end
