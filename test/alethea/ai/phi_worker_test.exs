defmodule Alethea.AI.PhiWorkerTest do
  @moduledoc """
  Contract tests for the real AI worker behind the boundary the Telegram
  worker tests mock (#392): what `PhiWorker.process/1` lets through to
  the model. `Req.Test` stands in for Ollama.
  """

  use Alethea.DataCase, async: false

  alias Alethea.AI.PhiWorker
  alias Alethea.Clinical.EmotionAnalysis

  setup do
    Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)
    :ok
  end

  describe "process/1 — sentiment regression" do
    test "stored emotion scores for the message are not supplied to the model" do
      message = insert_message_with_emotions()

      request =
        process_capturing_request(%{
          message_id: message.id,
          sanitized_content: "Hoy estuve muy triste.",
          history: []
        })

      supplied = Enum.map_join(request["messages"], "\n", & &1["content"])

      refute supplied =~ "0.875"
      refute supplied =~ "sadness"
      refute supplied =~ "Emoción dominante"
      refute supplied =~ "Análisis Emocional"

      assert List.last(request["messages"]) ==
               %{"role" => "user", "content" => "Hoy estuve muy triste."}
    end
  end

  describe "process/1 — sanitization at the last step before the model" do
    test "redacts identifiers even when the caller supplied them unsanitized" do
      request =
        process_capturing_request(%{
          message_id: Ecto.UUID.generate(),
          sanitized_content: "Escribime a paciente@example.com",
          history: [%{role: :patient, content: "Mi correo es otro@example.com"}]
        })

      supplied = Enum.map_join(request["messages"], "\n", & &1["content"])

      refute supplied =~ "paciente@example.com"
      refute supplied =~ "otro@example.com"
      assert supplied =~ "[REDACTED_EMAIL]"
    end
  end

  defp process_capturing_request(params) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:model_request, Jason.decode!(body)})
      Req.Test.json(conn, %{"message" => %{"content" => "Gracias por contarlo."}})
    end)

    assert {:ok, %{response: "Gracias por contarlo."}} = PhiWorker.process(params)
    assert_receive {:model_request, request}
    request
  end

  defp insert_message_with_emotions do
    {:ok, professional} =
      Alethea.Accounts.create_professional(%{
        email: "phi-#{System.unique_integer([:positive])}@alethea.com",
        password: "password1234",
        full_name: "Dra. Phi"
      })

    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{"alias" => "Paciente Phi", "professional_id" => professional.id},
        kek
      )

    {:ok, message} =
      Alethea.Clinical.save_message(
        patient,
        "Hoy estuve muy triste.",
        nil,
        "inbound",
        "spontaneous"
      )

    Repo.insert!(%EmotionAnalysis{
      message_id: message.id,
      joy_score: 0.025,
      sadness_score: 0.875,
      anger_score: 0.05,
      fear_score: 0.025,
      neutral_score: 0.025,
      dominant_label: "sadness",
      confidence: 0.875,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    message
  end
end
