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
end
