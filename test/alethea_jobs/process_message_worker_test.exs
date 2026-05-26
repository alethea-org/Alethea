defmodule AletheaJobs.ProcessMessageWorkerTest do
  use Alethea.DataCase, async: false

  import Mox

  alias AletheaJobs.ProcessMessageWorker
  alias Alethea.Accounts
  alias Alethea.WhatsApp.ConsentCache
  alias Alethea.Repo
  alias Alethea.Clinical.Message
  alias Alethea.AI.Diagnosis

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

    test "cuando el paciente ya aceptó términos, ejecuta el pipeline clínico completo" do
      professional = insert_professional()
      patient = insert_patient(professional, "+56944444444", "alias")

      phone = "+56944444444"
      text = "Necesito hablar"
      message_id = "wamid.123"

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{
           message_id: _message_id,
           raw_content: ^text,
           patient_context: _context
         } ->
        %{
          response: "Gracias por compartir",
          model_version: "phi-4-mini",
          source_message_id: message_id,
          behavior_type: :elicited
        }
      end)

      Alethea.WhatsApp.ClientMock
      |> expect(:send_message, fn ^phone, body ->
        assert body == "Gracias por compartir"
        {:ok, %{}}
      end)

      assert :ok = perform_job(%{"from" => phone, "text" => text, "whatsapp_message_id" => message_id})

      assert Repo.aggregate(Message, :count, :id) == 2
      assert Repo.aggregate(Diagnosis, :count, :id) == 1
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
