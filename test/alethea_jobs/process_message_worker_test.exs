defmodule AletheaJobs.ProcessMessageWorkerTest do
  use Alethea.DataCase, async: true

  import Mox
  alias AletheaJobs.ProcessMessageWorker
  alias Alethea.Accounts
  alias Alethea.Accounts.Patient
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
  end

  # Helpers

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
    # Generamos un hash para el test usando el secreto configurado en test.exs
    hash =
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:alethea, :phone_hash_secret),
        phone
      )
      |> Base.encode64()

    {:ok, patient} =
      %Patient{}
      |> Patient.changeset(%{
        whatsapp_number: phone,
        alias: alias_name,
        professional_id: professional.id,
        whatsapp_number_hash: hash,
        encrypted_whatsapp_number: "binary_data"
      })
      |> Alethea.Repo.insert()

    patient
  end
end
