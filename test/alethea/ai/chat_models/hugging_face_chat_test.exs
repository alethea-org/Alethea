defmodule Alethea.AI.ChatModels.HuggingFaceChatTest do
  @moduledoc """
  Tests for `Alethea.AI.ChatModels.HuggingFaceChat`, the custom LangChain
  ChatModel adapter for the Hugging Face Inference API.

  `call/3` returns the LangChain ChatModel contract:

    - `200 OK` with a non-empty `generated_text` → `{:ok, %Message{}}`
    - any API/transport error or unexpected body → `{:error, reason}`

  Errors surface through the adapter's internal `raise LangChainError` +
  `rescue` path, so this suite asserts the `{:error, _}` contract without
  hitting the network. `Req.Test` is wired via
  `Application.put_env(:alethea, :huggingface_chat_req_options, plug: {Req.Test, __MODULE__})`
  so `Req.post/2` hits the stub instead of the real Hugging Face API.
  """

  use ExUnit.Case, async: false

  alias Alethea.AI.ChatModels.HuggingFaceChat
  alias LangChain.Message

  @prompt "hola, buen día"

  setup do
    {:ok, model} =
      HuggingFaceChat.new(%{
        model: "meta-llama/Llama-2-7b-chat-hf",
        api_key: "test-hf-key-fake"
      })

    # Wire Req.Test as the plug. The adapter reads this config at
    # call-time and forwards it to Req.post/2.
    Application.put_env(
      :alethea,
      :huggingface_chat_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.delete_env(:alethea, :huggingface_chat_req_options) end)

    {:ok, model: model}
  end

  describe "call/3 — success" do
    test "returns {:ok, %Message{}} with the generated text on 200 OK", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!([%{"generated_text" => "estoy bien, gracias"}]))
      end)

      assert {:ok, %Message{} = message} = HuggingFaceChat.call(model, @prompt)
      assert message.content == "estoy bien, gracias"
    end
  end

  describe "call/3 — errors" do
    test "returns {:error, _} when the Hugging Face API responds with a non-200 status", %{
      model: model
    } do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal server error"}))
      end)

      assert {:error, reason} = HuggingFaceChat.call(model, @prompt)
      assert is_binary(reason)
      assert reason =~ "500"
    end

    test "returns {:error, _} when the API returns an error body on 200", %{model: model} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"error" => "model overloaded"}))
      end)

      assert {:error, reason} = HuggingFaceChat.call(model, @prompt)
      assert reason =~ "model overloaded"
    end

    test "returns {:error, _} when the transport fails (Req.post returns {:error, _})", %{
      model: model
    } do
      Req.Test.stub(__MODULE__, fn conn ->
        # Simulate a transport failure so Req.post/2 returns {:error, _},
        # exercising the adapter's transport-failure branch.
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, reason} = HuggingFaceChat.call(model, @prompt)
      assert is_binary(reason)
    end

    test "returns {:error, _} when streaming is requested (unsupported)", %{model: _model} do
      {:ok, streaming_model} =
        HuggingFaceChat.new(%{
          model: "meta-llama/Llama-2-7b-chat-hf",
          api_key: "test-hf-key-fake",
          stream: true
        })

      assert {:error, reason} = HuggingFaceChat.call(streaming_model, @prompt)
      assert reason =~ "Streaming is not supported"
    end
  end
end
