defmodule AletheaJobs.ProcessMessageWorkerTest do
  use Alethea.DataCase, async: false

  import Mox
  alias AletheaJobs.ProcessMessageWorker
  alias Alethea.Accounts
  alias Alethea.WhatsApp.ConsentCache

  # Make sure mocks are verified when the test ends
  setup :verify_on_exit!

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

      # Verificar que se marcó en el caché
      assert ConsentCache.in_progress?(phone)
    end

    test "si el consentimiento está en progreso, no vuelve a enviar los términos" do
      professional = insert_professional()
      _patient = insert_patient(professional, "+56922222222", "alias")

      phone = "+56922222222"
      text = "Hola de nuevo"

      ConsentCache.mark_in_progress(phone)

      # No esperamos ninguna llamada a send_message
      expect(Alethea.WhatsApp.ClientMock, :send_message, 0, fn _, _ -> {:ok, %{}} end)

      assert :ok = perform_job(%{"from" => phone, "text" => text})
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

      # Verificar actualización en DB
      updated_patient = Accounts.get_patient!(patient.id)
      assert updated_patient.terms_accepted == true
    end

    test "cuando el paciente ya aceptó términos, ejecuta el pipeline clínico", %{
      professional: prof
    } do
      # Pre-condición: paciente con términos aceptados
      patient = insert_patient(prof, "+56944444444", "Juan")
      {:ok, patient} = Accounts.update_patient_terms(patient, true)

      phone = "+56944444444"
      text = "Me siento un poco ansioso hoy."
      wamid = "wamid.#{System.unique_integer()}"

      # Expectativas:
      # 1. Inferencia IA
      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{raw_content: ^text} ->
        %{
          ai_response: "Entiendo. ¿Podrías contarme más sobre esa ansiedad?",
          model_version: "phi-4-mini",
          behavior_type: "elicited",
          extracted_emotions: %{"ansiedad" => 0.8}
        }
      end)

      # 2. Envío WhatsApp
      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body =~ "contarme más"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text, "whatsapp_message_id" => wamid})

      # Verificaciones en DB:
      # 1. Dos mensajes guardados (inbound y outbound)
      messages = Alethea.Clinical.list_recent_messages(patient.id)
      assert length(messages) == 2

      msg_in = Enum.find(messages, &(&1.direction == "inbound"))
      msg_out = Enum.find(messages, &(&1.direction == "outbound"))

      assert msg_in != nil
      assert msg_out != nil
      assert msg_in.behavior_type == "spontaneous"
      assert msg_in.whatsapp_message_id == wamid
      assert msg_out.behavior_type == "elicited"

      # 2. Un diagnóstico guardado vinculado al inbound
      diagnosis = List.first(Alethea.Repo.all(Alethea.AI.Diagnosis))
      assert diagnosis.message_id == msg_in.id
      assert diagnosis.ai_response =~ "Entiendo"
      assert diagnosis.extracted_emotions == %{"ansiedad" => 0.8}
    end
  end

  # Helpers

  defp perform_job(args) do
    %Oban.Job{args: args}
    |> ProcessMessageWorker.perform()
  end

  setup do
    # Necesitamos KEK para los tests clínicos
    professional = insert_professional()
    {:ok, kek} = Accounts.load_professional_kek(professional)
    %{professional: professional, kek: kek}
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
