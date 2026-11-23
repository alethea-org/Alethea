defmodule Alethea.AI.Whisper.OpenAICompatibleTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.Whisper.OpenAICompatible

  @audio <<0x4F, 0x67, 0x67, 0x53, 9, 8, 7>>

  setup do
    previous_settings = Application.get_env(:alethea, OpenAICompatible)
    previous_req = Application.get_env(:alethea, :whisper_req_options)

    Application.put_env(:alethea, OpenAICompatible,
      endpoint_url: "https://stt.test/openai/v1/",
      api_key: "sk-secret",
      model: "whisper-large-v3",
      receive_timeout: 5_000
    )

    Application.put_env(:alethea, :whisper_req_options, plug: {Req.Test, OpenAICompatible})

    on_exit(fn ->
      restore(OpenAICompatible, previous_settings)
      restore(:whisper_req_options, previous_req)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:alethea, key)
  defp restore(key, value), do: Application.put_env(:alethea, key, value)

  defp stub_json(status, body) do
    test_pid = self()

    Req.Test.stub(OpenAICompatible, fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))
      file = conn.body_params["file"]

      send(
        test_pid,
        {:request, conn.method, conn.host, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization"), Map.delete(conn.body_params, "file"),
         file && file.filename, file && file.content_type, file && File.read!(file.path)}
      )

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp response(segments) do
    %{
      "text" => "Hola. Bien.",
      "language" => "spanish",
      "duration" => 12.25,
      "segments" => segments
    }
  end

  test "posts multipart audio to /audio/transcriptions with bearer auth" do
    stub_json(200, response([]))

    assert {:ok, _} = OpenAICompatible.transcribe(@audio, content_type: "audio/ogg")

    assert_received {:request, "POST", "stt.test", "/openai/v1/audio/transcriptions", auth,
                     fields, filename, file_type, file_body}

    assert auth == ["Bearer sk-secret"]

    assert fields == %{
             "model" => "whisper-large-v3",
             "language" => "es",
             "response_format" => "verbose_json",
             "timestamp_granularities" => ["segment"]
           }

    assert filename == "audio.ogg"
    assert file_type == "audio/ogg"
    assert file_body == @audio
  end

  test "omits the authorization header when no key is configured" do
    Application.put_env(:alethea, OpenAICompatible, endpoint_url: "http://localhost:8000/v1")
    stub_json(200, response([]))

    assert {:ok, _} =
             OpenAICompatible.transcribe(@audio,
               content_type: "audio/webm;codecs=opus",
               language: "en"
             )

    assert_received {:request, "POST", "localhost", "/v1/audio/transcriptions", [], fields,
                     "audio.webm", _, _}

    assert fields["model"] == "whisper-1"
    assert fields["language"] == "en"
  end

  test "derives the file extension from the content type" do
    for {content_type, filename} <- [
          {"audio/mpeg", "audio.mp3"},
          {"audio/mp4", "audio.m4a"},
          {"audio/x-m4a", "audio.m4a"},
          {"audio/wav", "audio.wav"},
          {"video/mp4", "audio.mp4"}
        ] do
      stub_json(200, response([]))
      assert {:ok, _} = OpenAICompatible.transcribe(@audio, content_type: content_type)
      assert_received {:request, _, _, _, _, _, ^filename, _, _}
    end
  end

  test "parses segments without speakers, plus text, language and duration" do
    stub_json(
      200,
      response([
        %{"id" => 0, "start" => 0.0, "end" => 1.5, "text" => " Hola."},
        %{"id" => 1, "start" => 1.5, "end" => 2.0, "text" => "  "},
        %{"id" => 2, "start" => 2.0, "end" => 3.25, "text" => " Bien."}
      ])
    )

    assert OpenAICompatible.transcribe(@audio, content_type: "audio/webm") ==
             {:ok,
              %{
                text: "Hola. Bien.",
                language: "spanish",
                duration: 12.25,
                segments: [
                  %{start: 0.0, end: 1.5, text: "Hola.", speaker: nil},
                  %{start: 2.0, end: 3.25, text: "Bien.", speaker: nil}
                ]
              }}
  end

  test "a non-2xx status becomes {:error, {:http_status, status}}" do
    stub_json(429, %{"error" => %{"message" => "rate limited"}})

    assert OpenAICompatible.transcribe(@audio, content_type: "audio/webm") ==
             {:error, {:http_status, 429}}
  end

  test "a malformed response shape becomes {:error, :invalid_response}" do
    stub_json(200, %{"segments" => "nope"})

    assert OpenAICompatible.transcribe(@audio, content_type: "audio/webm") ==
             {:error, :invalid_response}
  end

  test "a timeout becomes {:error, :timeout}" do
    Req.Test.stub(OpenAICompatible, &Req.Test.transport_error(&1, :timeout))

    assert OpenAICompatible.transcribe(@audio, content_type: "audio/webm") == {:error, :timeout}
  end

  test "an unknown or missing content type is refused before any request" do
    Req.Test.stub(OpenAICompatible, fn _conn -> flunk("no request expected") end)

    assert OpenAICompatible.transcribe(@audio, content_type: "application/pdf") ==
             {:error, :unsupported_content_type}

    assert OpenAICompatible.transcribe(@audio, []) == {:error, :missing_content_type}
  end
end
