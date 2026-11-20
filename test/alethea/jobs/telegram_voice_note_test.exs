defmodule Alethea.Jobs.TelegramVoiceNoteTest do
  @moduledoc """
  Patient voice notes on Telegram (odd/tasks/telegram-voice-notes.md, S1-S5).

  A `voice` / `audio` update is routed by `TelegramMessageWorker` to
  `TelegramVoiceNoteWorker` (Oban, `:transcription` queue), which
  downloads the file through the Telegram client, transcribes it with
  `Alethea.AI.whisper()` and feeds the transcript through the same
  pipeline as a text message. Edge cases answer with fixed Spanish copy
  and never reach the AI reply pipeline.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.Clinical
  alias Alethea.Clinical.Message

  alias Alethea.Jobs.{
    TelegramBurstReplyWorker,
    TelegramMessageWorker,
    TelegramOutboundWorker,
    TelegramVoiceNoteWorker
  }

  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias Alethea.Telegram.Client.Fake
  alias Alethea.TranscriptionStub
  alias AletheaJobs.EmotionAnalysisWorker

  import Alethea.FoundationTestHelper
  import Ecto.Query

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @file_id "voice-file-id-1"

  @disabled_copy "Por ahora solo puedo leer mensajes escritos. ¿Me lo contás por texto?"
  @too_long_copy "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?"
  @unheard_copy "No pude escuchar bien el audio. ¿Me lo podés escribir?"

  setup :verify_on_exit!

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    start_supervised!(Fake)
    Fake.reset()

    Alethea.AI.PhiWorkerMock
    |> stub(:process, fn %{message_id: mid} ->
      {:ok,
       %{
         response: "respuesta clínica",
         source_message_id: mid,
         model_version: "phi-4-mini",
         behavior_type: :elicited
       }}
    end)

    bind_patient()
  end

  describe "Oban contract" do
    test "runs on the :transcription queue, 3 attempts, unique per Telegram update" do
      assert TelegramVoiceNoteWorker.__opts__()[:queue] == :transcription
      assert TelegramVoiceNoteWorker.__opts__()[:max_attempts] == 3

      assert TelegramVoiceNoteWorker.__opts__()[:unique] ==
               [period: 86_400, keys: [:telegram_update_id]]
    end
  end

  describe "routing (S1, S4)" do
    test "a voice update is handed to TelegramVoiceNoteWorker without downloading inline" do
      TranscriptionStub.install(%{text: "hola", segments: [], language: "es", duration: 2.0})

      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: voice_args(700, 70)})

      assert_enqueued(
        worker: TelegramVoiceNoteWorker,
        queue: :transcription,
        args: %{telegram_update_id: 700}
      )

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert Repo.aggregate(Message, :count, :id) == 0
      refute_enqueued(worker: TelegramOutboundWorker)
      refute_enqueued(worker: EmotionAnalysisWorker)
    end
  end

  describe "transcribed voice note (S1, S2)" do
    test "downloads, transcribes and runs the transcript through the text pipeline", ctx do
      transcript = "hoy me sentí tranquila en el trabajo"

      TranscriptionStub.install(%{text: transcript, segments: [], language: "es", duration: 4.0})

      parent = self()

      Alethea.AI.PhiWorkerMock
      |> expect(:process, fn %{message_id: mid, sanitized_content: content} ->
        send(parent, {:phi_worker_called, mid, content})

        {:ok,
         %{
           response: "respuesta clínica",
           source_message_id: mid,
           model_version: "phi-4-mini",
           behavior_type: :elicited
         }}
      end)

      assert :ok = run_voice_note(voice_args(701, 71))

      # The file was downloaded and the audio reached the provider.
      assert Fake.downloads() == [@file_id]
      assert_received {:transcription_stub_called, "fake-telegram-audio", opts}
      assert opts[:content_type] == "audio/ogg"
      assert opts[:language] == "es"

      # Stored as the patient's inbound message, marked as a voice note.
      inbound = Repo.one!(from m in Message, where: m.direction == "inbound")
      assert inbound.telegram_message_id == "71"
      assert inbound.media_type == "voice"
      assert inbound.patient_id == ctx.legacy_patient.id
      assert decrypt(inbound) == transcript

      # Sentiment regression: emotion analysis runs on the voice inbound.
      assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: inbound.id})

      # The AI reply pipeline is armed exactly as for text.
      assert :ok = run_burst_reply()
      assert_receive {:phi_worker_called, mid, ^transcript}
      assert mid == inbound.id

      outbound = Repo.one!(from m in Message, where: m.direction == "outbound")
      assert outbound.behavior_type == "elicited"
      assert outbound.media_type == nil

      assert_enqueued(
        worker: TelegramOutboundWorker,
        args: %{chat_id_hash: @chat_id_hash, message_id: outbound.id, lane: :safe}
      )
    end

    test "an audio file uses Telegram's mime_type as the content type" do
      TranscriptionStub.install(%{text: "te cuento", segments: [], language: "es", duration: 3.0})

      message =
        base_message(72)
        |> Map.put("audio", %{
          "file_id" => "audio-file-id",
          "duration" => 30,
          "mime_type" => "audio/mpeg"
        })

      assert :ok = run_voice_note(%{"telegram_update_id" => 702, "message" => message})

      assert Fake.downloads() == ["audio-file-id"]
      assert_received {:transcription_stub_called, _audio, opts}
      assert opts[:content_type] == "audio/mpeg"
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"
    end

    test "crisis wording in a voice note takes the crisis path" do
      TranscriptionStub.install(%{
        text: "me voy a quitar la vida",
        segments: [],
        language: "es",
        duration: 3.0
      })

      Phoenix.PubSub.subscribe(Alethea.PubSub, "psychologist:alerts")

      Alethea.AI.PhiWorkerMock
      |> expect(:process, 0, fn _ -> flunk("crisis must not invoke PhiWorker") end)

      assert :ok = run_voice_note(voice_args(703, 73))

      assert_receive {:crisis_detected, _alert}
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"

      assert Repo.exists?(
               from m in Message,
                 where: m.direction == "outbound" and m.behavior_type == "crisis_bypass"
             )

      assert_enqueued(worker: TelegramOutboundWorker, queue: :telegram_outbound_crisis)
      refute_enqueued(worker: TelegramBurstReplyWorker)
    end

    test "never logs the transcript, the chat id or the audio" do
      transcript = "algo muy privado que conté"

      TranscriptionStub.install(%{text: transcript, segments: [], language: "es", duration: 3.0})

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = run_voice_note(voice_args(704, 74))
        end)

      refute log =~ transcript
      refute log =~ "fake-telegram-audio"
      refute log =~ Integer.to_string(@chat_id)
      refute log =~ @chat_id_hash
    end
  end

  describe "edge cases (S3)" do
    test "transcription disabled: fixed reply once, no download, nothing stored" do
      previous = Application.fetch_env!(:alethea, :ai_whisper)
      Application.put_env(:alethea, :ai_whisper, Alethea.AI.Whisper.Disabled)
      on_exit(fn -> Application.put_env(:alethea, :ai_whisper, previous) end)

      assert :ok = run_voice_note(voice_args(710, 80))

      assert Fake.downloads() == []
      assert_only_notice(@disabled_copy)
    end

    test "voice longer than 10 minutes: fixed reply once, no download or transcription" do
      TranscriptionStub.install(%{
        text: "no debería",
        segments: [],
        language: "es",
        duration: 1.0
      })

      assert :ok = run_voice_note(voice_args(711, 81, duration: 601))

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@too_long_copy)
    end

    test "exactly 10 minutes is still transcribed" do
      TranscriptionStub.install(%{text: "largo", segments: [], language: "es", duration: 600.0})

      assert :ok = run_voice_note(voice_args(712, 82, duration: 600))

      assert Fake.downloads() == [@file_id]
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"
    end

    test "download failure retries, then the final attempt sends the fixed reply once" do
      TranscriptionStub.install(%{text: "hola", segments: [], language: "es", duration: 1.0})
      Fake.set_download_result({:error, {:http_error, 500}})

      args = voice_args(713, 83)

      assert {:error, _reason} = run_voice_note(args, attempt: 1)
      refute_enqueued(worker: TelegramOutboundWorker)

      assert :ok = run_voice_note(args, attempt: 3)
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@unheard_copy)
    end

    test "transcription failure on the final attempt sends the fixed reply once" do
      TranscriptionStub.install({:error, :timeout})

      args = voice_args(714, 84)
      assert {:error, :timeout} = run_voice_note(args, attempt: 2)
      refute_enqueued(worker: TelegramOutboundWorker)

      assert :ok = run_voice_note(args, attempt: 3)
      assert_only_notice(@unheard_copy)
    end

    test "an empty transcript sends the fixed reply without retrying" do
      TranscriptionStub.install(%{text: "   ", segments: [], language: "es", duration: 1.0})

      assert :ok = run_voice_note(voice_args(715, 85), attempt: 1)
      assert_only_notice(@unheard_copy)
    end
  end

  describe "idempotency" do
    test "a redelivered voice update is processed once" do
      TranscriptionStub.install(%{
        text: "hola de nuevo",
        segments: [],
        language: "es",
        duration: 1.0
      })

      args = voice_args(720, 90)

      # Telegram redelivers the same update: the webhook enqueues twice.
      Oban.insert!(TelegramMessageWorker.new(args))
      Oban.insert!(TelegramMessageWorker.new(args))
      assert [message_job] = all_enqueued(worker: TelegramMessageWorker)

      assert :ok = TelegramMessageWorker.perform(message_job)
      assert :ok = TelegramMessageWorker.perform(message_job)
      assert [voice_job] = all_enqueued(worker: TelegramVoiceNoteWorker)

      # Even a re-executed voice job resumes the same inbound row.
      assert :ok = TelegramVoiceNoteWorker.perform(voice_job)
      assert :ok = TelegramVoiceNoteWorker.perform(voice_job)

      assert Repo.aggregate(from(m in Message, where: m.direction == "inbound"), :count) == 1
      assert [_one_burst] = all_enqueued(worker: TelegramBurstReplyWorker)
      assert [_one_emotion] = all_enqueued(worker: EmotionAnalysisWorker)
    end
  end

  describe "other non-text messages (S5)" do
    test "a photo without caption is still dropped" do
      message =
        base_message(95)
        |> Map.put("photo", [%{"file_id" => "photo-file-id", "width" => 90, "height" => 90}])

      assert :ok =
               TelegramMessageWorker.perform(%Oban.Job{
                 args: %{"telegram_update_id" => 730, "message" => message}
               })

      assert Repo.aggregate(Message, :count, :id) == 0
      assert Fake.downloads() == []
      refute_enqueued(worker: TelegramVoiceNoteWorker)
      refute_enqueued(worker: TelegramOutboundWorker)
      refute_enqueued(worker: EmotionAnalysisWorker)
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # Runs the webhook-side worker, then the enqueued voice job the way
  # Oban would (string-keyed args, given attempt).
  defp run_voice_note(args, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    TelegramVoiceNoteWorker.perform(%Oban.Job{args: args, attempt: attempt, max_attempts: 3})
  end

  defp run_burst_reply do
    [job] = all_enqueued(worker: TelegramBurstReplyWorker)
    TelegramBurstReplyWorker.perform(%Oban.Job{args: job.args})
  end

  defp assert_only_notice(copy) do
    assert [job] = all_enqueued(worker: TelegramOutboundWorker)

    assert %{"body" => ^copy, "chat_id_hash" => @chat_id_hash, "message_id" => nil} = job.args

    assert job.queue == "telegram_outbound"
    assert Repo.aggregate(Message, :count, :id) == 0
    refute_enqueued(worker: TelegramBurstReplyWorker)
    refute_enqueued(worker: EmotionAnalysisWorker)
  end

  defp voice_args(update_id, message_id, opts \\ []) do
    voice =
      %{"file_id" => @file_id, "duration" => Keyword.get(opts, :duration, 5)}
      |> Map.put("mime_type", "audio/ogg")

    %{
      "telegram_update_id" => update_id,
      "message" => base_message(message_id) |> Map.put("voice", voice)
    }
  end

  defp base_message(message_id) do
    %{
      "message_id" => message_id,
      "date" => 1_700_000_000,
      "chat" => %{"id" => @chat_id, "type" => "private"}
    }
  end

  defp decrypt(%Message{} = message) do
    {:ok, legacy_patient} =
      Alethea.Foundation.Accounts.legacy_patient(
        Repo.get_by!(Alethea.Foundation.Accounts.Patient, legacy_patient_id: message.patient_id)
      )

    {:ok, dek} = Clinical.patient_dek(legacy_patient)
    {:ok, plaintext} = Clinical.decrypt_message_content(message, dek)
    plaintext
  end

  defp bind_patient do
    foundation_pro = professional_fixture()
    foundation_pat = patient_fixture(foundation_pro, %{alias: "Pat#{System.unique_integer()}"})

    legacy_pro = legacy_professional_fixture()
    legacy_pat = legacy_patient_fixture(legacy_pro)

    foundation_pat =
      foundation_pat
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_pat.id
      })
      |> Repo.update!()

    %{foundation_patient: foundation_pat, legacy_patient: legacy_pat}
  end
end
