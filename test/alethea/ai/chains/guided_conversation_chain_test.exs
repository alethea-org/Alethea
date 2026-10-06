defmodule Alethea.AI.Chains.GuidedConversationChainTest do
  @moduledoc """
  Contract tests for what `GuidedConversationChain` sends to the model
  (#392). The worker-level tests control the boundary above this chain,
  so the request the model actually receives can only be established
  here. `Req.Test` stands in for Ollama; nothing leaves the process.
  """

  use ExUnit.Case, async: false

  alias Alethea.AI.Chains.GuidedConversationChain
  alias Alethea.AI.JournalingPrompt
  alias LangChain.Message

  setup do
    Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)
    :ok
  end

  describe "run/1 — conversation roles" do
    test "sends prior turns as distinct patient and Alethea messages, then the current turn" do
      request =
        run_capturing_request(%{
          sanitized_content: "Hoy me costó levantarme.",
          history: [
            %{role: :patient, content: "Ayer discutí con mi jefe."},
            %{role: :alethea, content: "Gracias por contarlo. ¿Qué pasó después?"}
          ],
          message_id: "msg-1"
        })

      assert [%{"role" => "system"} | conversation] = request["messages"]

      assert conversation == [
               %{"role" => "user", "content" => "Ayer discutí con mi jefe."},
               %{"role" => "assistant", "content" => "Gracias por contarlo. ¿Qué pasó después?"},
               %{"role" => "user", "content" => "Hoy me costó levantarme."}
             ]
    end

    test "keeps conversation content out of the system message" do
      request =
        run_capturing_request(%{
          sanitized_content: "Hoy me costó levantarme.",
          history: [%{role: :patient, content: "Ayer discutí con mi jefe."}],
          message_id: "msg-2"
        })

      [%{"role" => "system", "content" => instructions} | _conversation] = request["messages"]

      refute instructions =~ "Ayer discutí con mi jefe."
      refute instructions =~ "Hoy me costó levantarme."
    end
  end

  describe "run/1 — instructions and generation bounds" do
    test "sends the journaling instructions as the only system message" do
      request =
        run_capturing_request(%{
          sanitized_content: "Hoy me costó levantarme.",
          history: [%{role: :alethea, content: "¿Cómo estuvo tu día?"}],
          message_id: "msg-4"
        })

      assert [%{"role" => "system", "content" => instructions}] =
               Enum.filter(request["messages"], &(&1["role"] == "system"))

      assert instructions == JournalingPrompt.system_prompt()
    end

    test "bounds the reply length through the generation configuration" do
      request =
        run_capturing_request(%{
          sanitized_content: "Hoy me costó levantarme.",
          history: [],
          message_id: "msg-5"
        })

      assert request["options"]["num_predict"] == 160
      assert GuidedConversationChain.suggested_max_tokens() == 160
    end
  end

  describe "truncated?/1" do
    test "is true only for a model message that stopped at the length limit" do
      assert GuidedConversationChain.truncated?(%Message{role: :assistant, status: :length})
      refute GuidedConversationChain.truncated?(%Message{role: :assistant, status: :complete})
    end
  end

  describe "run/1 — result" do
    test "reports a reply the model finished on its own as not truncated" do
      stub_reply("Gracias por contarlo. ¿Cómo lo viviste?")

      assert {:ok, %{truncated: false}} =
               GuidedConversationChain.run(%{
                 sanitized_content: "Hoy me costó levantarme.",
                 history: [],
                 message_id: "msg-6"
               })
    end

    test "anchors the reply to the source message and tags it as elicited" do
      stub_reply("Gracias por contarlo. ¿Cómo lo viviste?")

      assert {:ok, result} =
               GuidedConversationChain.run(%{
                 sanitized_content: "Hoy me costó levantarme.",
                 history: [],
                 message_id: "msg-3"
               })

      assert result.response == "Gracias por contarlo. ¿Cómo lo viviste?"
      assert result.source_message_id == "msg-3"
      assert result.behavior_type == :elicited
    end
  end

  describe "run/1 — model failure" do
    test "returns an error tuple when the model call fails" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, _reason} =
               GuidedConversationChain.run(%{
                 sanitized_content: "Hoy me costó levantarme.",
                 history: [],
                 message_id: "msg-7"
               })
    end
  end

  defp run_capturing_request(params) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:model_request, Jason.decode!(body)})
      Req.Test.json(conn, %{"message" => %{"content" => "Gracias por contarlo."}})
    end)

    assert {:ok, _result} = GuidedConversationChain.run(params)
    assert_receive {:model_request, request}
    request
  end

  defp stub_reply(content) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"message" => %{"content" => content}})
    end)
  end
end
