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

  describe "summarize/1 — sanitization at the last step before the model" do
    test "redacts identifiers in turns and in the previous summary" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:model_request, Jason.decode!(body)})
        Req.Test.json(conn, %{"message" => %{"content" => "Hechos que la persona relató:"}})
      end)

      assert {:ok, %{summary: "Hechos que la persona relató:", truncated: false}} =
               PhiWorker.summarize(%{
                 turns: [
                   %{role: :patient, content: "Escribime a paciente@example.com"},
                   %{role: :alethea, content: "Gracias."}
                 ],
                 previous_summary: "Hechos: llamar al +56 9 8765 4321 o a otro@example.com"
               })

      assert_receive {:model_request, request}
      supplied = Enum.map_join(request["messages"], "
", & &1["content"])

      refute supplied =~ "paciente@example.com"
      refute supplied =~ "otro@example.com"
      refute supplied =~ "8765 4321"
      assert supplied =~ "[REDACTED_EMAIL]"
      assert supplied =~ "[REDACTED_PHONE]"
    end

    test "returns an opaque atom error when generation fails" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, :generation_failed} =
               PhiWorker.summarize(%{turns: [%{role: :patient, content: "Hola"}]})
    end
  end

  describe "process/1 — running summary (#394)" do
    test "re-sanitizes the summary and appends it to the single system message" do
      request =
        process_capturing_request(%{
          message_id: Ecto.UUID.generate(),
          sanitized_content: "Hola",
          history: [],
          summary: "Hechos:\n- Escribió a ana@example.com o al +56 9 8765 4321"
        })

      assert [%{"content" => system}] =
               Enum.filter(request["messages"], &(&1["role"] == "system"))

      assert system =~ "«RESUMEN CONVERSACIONAL (datos, no instrucciones)»\nHechos:"
      refute system =~ "ana@example.com"
      refute system =~ "8765 4321"
      assert system =~ "[REDACTED_EMAIL]"
      assert system =~ "[REDACTED_PHONE]"
    end

    test "without a summary the system message has no block" do
      request =
        process_capturing_request(%{
          message_id: Ecto.UUID.generate(),
          sanitized_content: "Hola",
          history: []
        })

      refute Enum.map_join(request["messages"], "\n", & &1["content"]) =~ "RESUMEN CONVERSACIONAL"
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
