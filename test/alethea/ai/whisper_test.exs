defmodule Alethea.AI.WhisperTest do
  @moduledoc """
  Behaviour contract tests for `Alethea.AI.Whisper` and its Fake adapter.

  Per `openspec/sdd/bootstrap-alethea-v2/specs/ai/spec.md`:

  - The behaviour declares `transcribe/2`.
  - `behaviour_info(:callbacks)` returns `[{:transcribe, 2}]`.
  - A module that `use Alethea.AI.Whisper` without `transcribe/2` gets
    a compiler warning.
  - The Fake adapter returns an empty `transcription()` map for any
    input shape (binary or string path).
  """

  use ExUnit.Case, async: true

  alias Alethea.AI.Whisper

  describe "behaviour contract" do
    test "behaviour_info/1 lists transcribe/2" do
      callbacks = Whisper.behaviour_info(:callbacks)
      assert {:transcribe, 2} in callbacks
    end

    test "use Alethea.AI.Whisper without transcribe/2 emits a compiler warning" do
      code = """
      defmodule Alethea.AI.WhisperTest.WarningProbe do
        use Alethea.AI.Whisper
        # NOTE: transcribe/2 is intentionally missing
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)
      |> tap(&send(self(), {:stderr, &1}))
      |> then(fn _ -> :ok end)

      assert_received {:stderr, stderr}
      assert stderr =~ "transcribe"
    end
  end

  describe "Alethea.AI.Whisper.Fake adapter" do
    alias Alethea.AI.Whisper.Fake

    test "transcribe/2 with a string path returns the empty transcription" do
      assert {:ok, transcription} = Fake.transcribe("/tmp/audio.mp3", [])
      assert transcription.text == ""
      assert transcription.segments == []
      assert transcription.language == nil
      assert transcription.duration == nil
    end

    test "transcribe/2 with a raw binary returns the empty transcription" do
      audio = <<1, 2, 3, 4, 5>>
      assert {:ok, transcription} = Fake.transcribe(audio, [])
      assert transcription.text == ""
      assert transcription.segments == []
      assert transcription.language == nil
    end

    test "transcribe/2 returns the same shape for both string and binary inputs" do
      # Triangulation: the spec says the first arg is binary() | String.t()
      # (i.e., a file path or a raw audio binary). The adapter must
      # accept both without erroring.
      string_result = Fake.transcribe("/path/to/audio.ogg", language: "es")
      binary_result = Fake.transcribe(<<0xFF, 0xFB>>, language: "es")

      assert {:ok, _} = string_result
      assert {:ok, _} = binary_result
    end

    test "transcribe/2 ignores opts (deterministic empty transcription)" do
      # Triangulation: deterministic across opts — the Fake is a
      # no-op, the real adapter (Groq) will return real text.
      assert {:ok, t1} = Fake.transcribe("/a", model: "whisper-large")
      assert {:ok, t2} = Fake.transcribe("/a", model: "whisper-tiny")
      assert t1 == t2
    end
  end

  describe "runtime_config/1" do
    alias Alethea.AI.Whisper.{Deepgram, Disabled, OpenAICompatible}

    test "an unset or false switch wires the Disabled adapter" do
      assert Whisper.runtime_config(%{}) == [ai_whisper: Disabled]
      assert Whisper.runtime_config(%{"WHISPER_ENABLED" => "false"}) == [ai_whisper: Disabled]
    end

    test "any other switch value raises" do
      assert_raise RuntimeError, ~r/WHISPER_ENABLED must be exactly true or false/, fn ->
        Whisper.runtime_config(%{"WHISPER_ENABLED" => "yes"})
      end
    end

    test "an enabled switch without a provider raises" do
      assert_raise RuntimeError, ~r/TRANSCRIPTION_PROVIDER is missing or empty/, fn ->
        Whisper.runtime_config(%{"WHISPER_ENABLED" => "true"})
      end
    end

    test "an unknown provider raises" do
      assert_raise RuntimeError,
                   ~r/TRANSCRIPTION_PROVIDER must be deepgram or openai_compatible/,
                   fn ->
                     Whisper.runtime_config(%{
                       "WHISPER_ENABLED" => "true",
                       "TRANSCRIPTION_PROVIDER" => "x"
                     })
                   end
    end

    test "deepgram selects its adapter with defaults" do
      env = %{
        "WHISPER_ENABLED" => "true",
        "TRANSCRIPTION_PROVIDER" => "deepgram",
        "DEEPGRAM_API_KEY" => " dg-key "
      }

      assert Whisper.runtime_config(env) == [
               {:ai_whisper, Deepgram},
               {Deepgram,
                [
                  api_key: "dg-key",
                  model: "nova-3",
                  base_url: "https://api.deepgram.com",
                  receive_timeout: 600_000
                ]}
             ]
    end

    test "deepgram honours its optional overrides" do
      env = %{
        "WHISPER_ENABLED" => "true",
        "TRANSCRIPTION_PROVIDER" => "deepgram",
        "DEEPGRAM_API_KEY" => "dg-key",
        "DEEPGRAM_MODEL" => "nova-2",
        "DEEPGRAM_BASE_URL" => "https://dg.example.com",
        "WHISPER_RECEIVE_TIMEOUT_MS" => "1000"
      }

      assert [{:ai_whisper, Deepgram}, {Deepgram, settings}] = Whisper.runtime_config(env)
      assert settings[:model] == "nova-2"
      assert settings[:base_url] == "https://dg.example.com"
      assert settings[:receive_timeout] == 1000
    end

    test "deepgram without its key raises without echoing values" do
      assert_raise RuntimeError, ~r/DEEPGRAM_API_KEY is missing or empty/, fn ->
        Whisper.runtime_config(%{
          "WHISPER_ENABLED" => "true",
          "TRANSCRIPTION_PROVIDER" => "deepgram",
          "DEEPGRAM_API_KEY" => "  "
        })
      end
    end

    test "openai_compatible selects its adapter with defaults and an optional key" do
      env = %{
        "WHISPER_ENABLED" => "true",
        "TRANSCRIPTION_PROVIDER" => "openai_compatible",
        "WHISPER_ENDPOINT_URL" => "https://api.groq.com/openai/v1"
      }

      assert Whisper.runtime_config(env) == [
               {:ai_whisper, OpenAICompatible},
               {OpenAICompatible,
                [
                  endpoint_url: "https://api.groq.com/openai/v1",
                  api_key: nil,
                  model: "whisper-1",
                  receive_timeout: 600_000
                ]}
             ]

      env = Map.merge(env, %{"WHISPER_API_KEY" => "gsk", "WHISPER_MODEL" => "whisper-large-v3"})
      assert [_, {OpenAICompatible, settings}] = Whisper.runtime_config(env)
      assert settings[:api_key] == "gsk"
      assert settings[:model] == "whisper-large-v3"
    end

    test "openai_compatible without an endpoint raises" do
      assert_raise RuntimeError, ~r/WHISPER_ENDPOINT_URL is missing or empty/, fn ->
        Whisper.runtime_config(%{
          "WHISPER_ENABLED" => "true",
          "TRANSCRIPTION_PROVIDER" => "openai_compatible"
        })
      end
    end

    test "a non-positive receive timeout raises" do
      assert_raise RuntimeError, ~r/WHISPER_RECEIVE_TIMEOUT_MS must be a positive integer/, fn ->
        Whisper.runtime_config(%{
          "WHISPER_ENABLED" => "true",
          "TRANSCRIPTION_PROVIDER" => "openai_compatible",
          "WHISPER_ENDPOINT_URL" => "http://localhost:8000/v1",
          "WHISPER_RECEIVE_TIMEOUT_MS" => "0"
        })
      end
    end
  end
end
