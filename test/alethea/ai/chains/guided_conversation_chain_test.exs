defmodule Alethea.AI.Chains.GuidedConversationChainTest do
  @moduledoc """
  Contract tests for what `GuidedConversationChain` sends to the model
  (#392). The worker-level tests control the boundary above this chain,
  so the request the model actually receives can only be established
  here. `Req.Test` stands in for Ollama; nothing leaves the process.
  """

  use ExUnit.Case, async: false

  alias Alethea.AI.Chains.GuidedConversationChain

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

  describe "run/1 — result" do
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
