defmodule Alethea.AI.Whisper.DeepgramTest do
  use ExUnit.Case, async: false

  alias Alethea.AI.Whisper.Deepgram

  @audio <<0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3>>

  setup do
    previous_settings = Application.get_env(:alethea, Deepgram)
    previous_req = Application.get_env(:alethea, :whisper_req_options)

    Application.put_env(:alethea, Deepgram,
      api_key: "dg-secret",
      model: "nova-3",
      base_url: "https://deepgram.test/",
      receive_timeout: 5_000
    )

    Application.put_env(:alethea, :whisper_req_options, plug: {Req.Test, Deepgram})

    on_exit(fn ->
      restore(Deepgram, previous_settings)
      restore(:whisper_req_options, previous_req)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:alethea, key)
  defp restore(key, value), do: Application.put_env(:alethea, key, value)

  defp stub_json(status, body) do
    test_pid = self()

    Req.Test.stub(Deepgram, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, conn.method, conn.host, conn.request_path,
         Plug.Conn.fetch_query_params(conn).query_params,
         Plug.Conn.get_req_header(conn, "authorization"),
         Plug.Conn.get_req_header(conn, "content-type"), raw}
      )

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp word(word, start, finish, speaker),
    do: %{"word" => word, "start" => start, "end" => finish, "speaker" => speaker}

  defp response(utterances, words \\ []) do
    %{
      "metadata" => %{"duration" => 42.5},
      "results" => %{
        "channels" => [
          %{"alternatives" => [%{"transcript" => "Hola. ¿Cómo estás?", "words" => words}]}
        ],
        "utterances" => utterances
      }
    }
  end

  test "posts the raw audio to /v1/listen with diarization query and token auth" do
    stub_json(200, response([]))

    assert {:ok, _} = Deepgram.transcribe(@audio, content_type: "audio/webm")

    assert_received {:request, "POST", "deepgram.test", "/v1/listen", query, auth, content_type,
                     body}

    assert query == %{
             "model" => "nova-3",
             "language" => "es",
             "utterances" => "true",
             "diarize_model" => "latest",
             "punctuate" => "true",
             "smart_format" => "true"
           }

    refute Map.has_key?(query, "diarize")
    assert auth == ["Token dg-secret"]
    assert content_type == ["audio/webm"]
    assert body == @audio
  end

  test "passes the requested language through" do
    stub_json(200, response([]))

    assert {:ok, %{language: "en"}} =
             Deepgram.transcribe(@audio, content_type: "audio/ogg", language: "en")

    assert_received {:request, _, _, _, %{"language" => "en"}, _, ["audio/ogg"], _}
  end

  test "parses utterances into speaker segments, text and duration" do
    utterances = [
      %{"start" => 0.0, "end" => 1.2, "transcript" => "Hola.", "speaker" => 0},
      %{"start" => 1.5, "end" => 3.0, "transcript" => "¿Cómo estás?", "speaker" => 1}
    ]

    stub_json(200, response(utterances))

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") ==
             {:ok,
              %{
                text: "Hola. ¿Cómo estás?",
                language: "es",
                duration: 42.5,
                segments: [
                  %{start: 0.0, end: 1.2, text: "Hola.", speaker: 0},
                  %{start: 1.5, end: 3.0, text: "¿Cómo estás?", speaker: 1}
                ]
              }}
  end

  test "falls back to the majority word speaker when an utterance lacks one" do
    utterances = [%{"start" => 0.0, "end" => 2.0, "transcript" => "uno dos tres"}]

    words = [
      word("uno", 0.0, 0.5, 1),
      word("dos", 0.6, 1.0, 1),
      word("tres", 1.1, 1.9, 0),
      word("fuera", 2.5, 3.0, 0),
      word("lejos", 3.1, 3.5, 0)
    ]

    stub_json(200, response(utterances, words))

    assert {:ok, %{segments: [%{speaker: 1, text: "uno dos tres"}]}} =
             Deepgram.transcribe(@audio, content_type: "audio/webm")
  end

  test "speaker is nil when neither the utterance nor its words carry one" do
    utterances = [%{"start" => 0.0, "end" => 2.0, "transcript" => "hola"}]
    words = [%{"word" => "hola", "start" => 0.1, "end" => 0.4}]
    stub_json(200, response(utterances, words))

    assert {:ok, %{segments: [%{speaker: nil, text: "hola"}]}} =
             Deepgram.transcribe(@audio, content_type: "audio/webm")
  end

  test "drops blank utterances" do
    utterances = [
      %{"start" => 0.0, "end" => 0.5, "transcript" => "   ", "speaker" => 0},
      %{"start" => 0.5, "end" => 1.0, "transcript" => "Bien.", "speaker" => 1}
    ]

    stub_json(200, response(utterances))

    assert {:ok, %{segments: [%{text: "Bien.", speaker: 1}]}} =
             Deepgram.transcribe(@audio, content_type: "audio/webm")
  end

  test "a non-2xx status becomes {:error, {:http_status, status}}" do
    stub_json(401, %{"err_code" => "INVALID_AUTH"})

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") ==
             {:error, {:http_status, 401}}
  end

  test "a malformed response shape becomes {:error, :invalid_response}" do
    stub_json(200, %{"results" => %{"channels" => []}})

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") ==
             {:error, :invalid_response}
  end

  test "an utterance with a non-numeric start is an invalid response" do
    stub_json(200, response([%{"start" => "x", "end" => 1, "transcript" => "a", "speaker" => 0}]))

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") ==
             {:error, :invalid_response}
  end

  test "a timeout becomes {:error, :timeout}" do
    Req.Test.stub(Deepgram, &Req.Test.transport_error(&1, :timeout))

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") == {:error, :timeout}
  end

  test "other transport errors are returned without raising" do
    Req.Test.stub(Deepgram, &Req.Test.transport_error(&1, :econnrefused))

    assert Deepgram.transcribe(@audio, content_type: "audio/webm") ==
             {:error, {:transport, :econnrefused}}
  end

  test "a missing content type is refused before any request" do
    Req.Test.stub(Deepgram, fn _conn -> flunk("no request expected") end)

    assert Deepgram.transcribe(@audio, []) == {:error, :missing_content_type}
  end
end
