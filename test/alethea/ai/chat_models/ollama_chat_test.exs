defmodule Alethea.AI.ChatModels.OllamaChatTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.ChatModels.OllamaChat
  alias LangChain.Message

  setup do
    Application.put_env(:alethea, :ollama_chat_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn -> Application.delete_env(:alethea, :ollama_chat_req_options) end)

    {:ok,
     model:
       OllamaChat.new!(%{
         model: "phi4-mini",
         endpoint_url: "http://localhost:11434",
         temperature: 0.0,
         max_tokens: 512
       })}
  end

  test "uses Ollama's non-streaming chat contract", %{model: model} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/chat"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "phi4-mini"
      assert payload["stream"] == false
      assert payload["options"] == %{"num_predict" => 512, "temperature" => 0.0}
      assert Enum.any?(payload["messages"], &(&1 == %{"role" => "user", "content" => "hello"}))

      Req.Test.json(conn, %{
        "model" => "phi4-mini",
        "message" => %{"role" => "assistant", "content" => "How are you feeling?"},
        "done" => true
      })
    end)

    assert {:ok, %Message{content: "How are you feeling?"}} = OllamaChat.call(model, "hello")
  end

  describe "call/3 — how the generation ended" do
    test "marks a reply Ollama stopped at the token limit as length-limited", %{model: model} do
      stub_response(%{
        "message" => %{"role" => "assistant", "content" => "Gracias por contarlo. Me pregunto si"},
        "done" => true,
        "done_reason" => "length"
      })

      assert {:ok, %Message{status: :length, content: "Gracias por contarlo. Me pregunto si"}} =
               OllamaChat.call(model, "hola")
    end

    test "keeps a reply the model finished on its own complete", %{model: model} do
      stub_response(%{
        "message" => %{"role" => "assistant", "content" => "Gracias por contarlo."},
        "done" => true,
        "done_reason" => "stop"
      })

      assert {:ok, %Message{status: :complete}} = OllamaChat.call(model, "hola")
    end

    test "keeps a reply complete when Ollama reports no reason", %{model: model} do
      stub_response(%{
        "message" => %{"role" => "assistant", "content" => "Gracias por contarlo."},
        "done" => true
      })

      assert {:ok, %Message{status: :complete}} = OllamaChat.call(model, "hola")
    end
  end

  defp stub_response(body) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end
end
