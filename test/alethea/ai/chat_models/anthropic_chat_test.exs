defmodule Alethea.AI.ChatModels.AnthropicChatTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Alethea.AI.ChatModels.AnthropicChat
  alias LangChain.Message

  setup do
    original = Application.fetch_env(:alethea, :anthropic_chat_req_options)

    Application.put_env(:alethea, :anthropic_chat_req_options, plug: {Req.Test, __MODULE__})
    # Retries back off for real in production; tests cap every delay at 0 ms.
    Application.put_env(:alethea, :anthropic_retry_max_delay_ms, 0)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:alethea, :anthropic_chat_req_options, value)
        :error -> Application.delete_env(:alethea, :anthropic_chat_req_options)
      end

      Application.delete_env(:alethea, :anthropic_retry_max_delay_ms)
    end)

    :ok
  end

  test "rejects blank credentials and never serializes them" do
    for blank <- [nil, "", " \t\n"] do
      assert {:error, %{type: "invalid_config"}} =
               AnthropicChat.new(%{model: "claude-test-model", api_key: blank})
    end

    model = model()
    refute inspect(model) =~ "synthetic-secret-key"
    refute inspect(AnthropicChat.serialize_config(model)) =~ "synthetic-secret-key"
  end

  test "serializes the system separately and preserves text, roles and length termination" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "Demo reply"}],
        "stop_reason" => "max_tokens"
      })
    end)

    assert {:ok, %Message{content: "Demo reply", status: :length}} =
             AnthropicChat.call(model(), [
               Message.new_system!("Demo instructions"),
               Message.new_user!("Demo input")
             ])

    assert_receive {:request, "/v1/messages", headers, body}
    assert {"x-api-key", "synthetic-secret-key"} in headers
    assert body["model"] == "claude-test-model"
    assert body["system"] == "Demo instructions"
    assert [%{"role" => "user", "content" => content}] = body["messages"]
    assert content == "Demo input" or content == [%{"type" => "text", "text" => "Demo input"}]
    assert body["stream"] == false
    assert body["max_tokens"] == 80
  end

  test "provider failures and malformed responses cannot leak markers in errors or logs" do
    marker = "SYNTHETIC_PRIVATE_MARKER"

    failures =
      Enum.map([400, 401, 403, 429, 500, 503], &{&1, %{"error" => %{"message" => marker}}}) ++
        Enum.map(
          [
            %{},
            %{"content" => []},
            %{"content" => marker},
            %{"content" => [%{"type" => "text", "text" => "  "}], "stop_reason" => "end_turn"},
            %{"content" => [%{"type" => "text", "text" => marker}], "stop_reason" => "tool_use"},
            %{
              "content" => [%{"type" => "tool_use", "input" => marker}],
              "stop_reason" => "end_turn"
            }
          ],
          &{200, &1}
        )

    for {status, body} <- failures do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      log =
        capture_log(fn ->
          assert {:error, reason} = AnthropicChat.call(model(), marker)
          refute inspect(reason) =~ marker
          refute inspect(reason) =~ "synthetic-secret-key"
        end)

      refute log =~ marker
      refute log =~ "synthetic-secret-key"
    end
  end

  test "rejects streaming and tools rather than silently ignoring them" do
    Req.Test.stub(__MODULE__, fn _ -> flunk("unsupported options must not send HTTP") end)
    assert {:error, %{type: "unsupported"}} = AnthropicChat.call(model(stream: true), "Demo")
    assert {:error, %{type: "unsupported"}} = AnthropicChat.call(model(), "Demo", [%{}])
  end

  test "preserves multiple text blocks for every supported termination reason" do
    for {stop, status} <- [
          {"end_turn", :complete},
          {"stop_sequence", :complete},
          {"max_tokens", :length}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "content" => [
            %{"type" => "text", "text" => "First"},
            %{"type" => "text", "text" => " second"}
          ],
          "stop_reason" => stop
        })
      end)

      assert {:ok, %Message{content: "First second", status: ^status}} =
               AnthropicChat.call(model(), "Demo")
    end
  end

  test "raised transport failures cannot leak markers in returned errors or logs" do
    Req.Test.stub(__MODULE__, fn _ -> raise "SYNTHETIC_PRIVATE_MARKER" end)

    log =
      capture_log(fn ->
        assert {:error, error} = AnthropicChat.call(model(), "SYNTHETIC_PRIVATE_MARKER")
        assert error.type == "request_failed"
        assert Exception.message(error) == "Anthropic request failed"
        refute inspect(error) =~ "SYNTHETIC_PRIVATE_MARKER"
      end)

    refute log =~ "SYNTHETIC_PRIVATE_MARKER"
    refute log =~ "synthetic-secret-key"
  end

  test "strips temperature from payload for haiku-5 models to avoid Anthropic HTTP 400" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "temperature")

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn"
      })
    end)

    haiku_model = model(model: "claude-haiku-5-5", temperature: 0.0)
    assert {:ok, %Message{content: "ok"}} = AnthropicChat.call(haiku_model, "di ok")
  end

  test "transport failures report a payload-free reason class" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:error, error} = AnthropicChat.call(model(), "SYNTHETIC_PRIVATE_MARKER")
    assert error.type == "request_failed"
    assert Exception.message(error) == "Anthropic request failed: timeout"
  end

  test "retries transient overload and rate limits, then succeeds" do
    for status <- [429, 529, 503] do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => %{}})

          _ ->
            Req.Test.json(conn, %{
              "content" => [%{"type" => "text", "text" => "ok"}],
              "stop_reason" => "end_turn"
            })
        end
      end)

      assert {:ok, %Message{content: "ok"}} = AnthropicChat.call(model(), "di ok")
      assert Agent.get(calls, & &1) == 2
    end
  end

  test "a long Retry-After is capped and timeouts are not retried" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "3600")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{}})

        _ ->
          Req.Test.json(conn, %{
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn"
          })
      end
    end)

    {elapsed_us, result} = :timer.tc(fn -> AnthropicChat.call(model(), "x") end)
    assert {:ok, %Message{content: "ok"}} = result
    assert elapsed_us < 1_000_000

    {:ok, timeouts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(timeouts, &(&1 + 1))
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %{type: "request_failed"}} = AnthropicChat.call(model(), "x")
    assert Agent.get(timeouts, & &1) == 1
  end

  test "error types carry the HTTP status, and auth failures are not retried" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{}})
    end)

    assert {:error, %{type: "http_error.401"}} = AnthropicChat.call(model(), "x")
    assert Agent.get(calls, & &1) == 1

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(529) |> Req.Test.json(%{"error" => %{}})
    end)

    assert {:error, %{type: "http_error.529"}} = AnthropicChat.call(model(), "x")
  end

  test "keeps temperature for models that accept it" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["temperature"] == 0.3

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "stop_reason" => "end_turn"
      })
    end)

    assert {:ok, %Message{content: "ok"}} =
             AnthropicChat.call(model(model: "claude-test-model", temperature: 0.3), "di ok")
  end

  test "restore_from_map follows the LangChain callback contract" do
    serialized = AnthropicChat.serialize_config(model())

    assert {:error, message} = AnthropicChat.restore_from_map(serialized)
    assert is_binary(message)
    refute message =~ "synthetic-secret-key"

    assert {:ok, %AnthropicChat{model: "claude-test-model"}} =
             AnthropicChat.restore_from_map(Map.put(serialized, :api_key, "synthetic-secret-key"))
  end

  defp model(overrides \\ []) do
    attrs =
      Map.merge(
        %{api_key: "synthetic-secret-key", model: "claude-test-model", max_tokens: 80},
        Map.new(overrides)
      )

    AnthropicChat.new!(attrs)
  end
end
