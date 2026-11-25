defmodule Alethea.Jobs.TelegramVoiceNoteWorkerTest do
  @moduledoc """
  Bounds and sealed args of `Alethea.Jobs.TelegramVoiceNoteWorker`
  (odd/tasks/security-audit-run-1.md, S4 and S7).

    * S7: a size cap checked before download (and on the downloaded
      bytes), a note with no `duration` bounded by its `file_size`, a
      per-patient rolling cap on transcriptions, and an own queue.
    * S4: the Telegram message map is sealed in `oban_jobs.args`; jobs
      in the legacy plaintext shape still run.

  The happy path and the fixed-copy edge cases live in
  `telegram_voice_note_test.exs`.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox

  alias Alethea.Clinical.Message
  alias Alethea.Jobs.{TelegramMessageWorker, TelegramOutboundWorker, TelegramVoiceNoteWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.{ChatIdHash, JobPayload}
  alias Alethea.Telegram.Client.Fake
  alias Alethea.TranscriptionStub

  import Alethea.FoundationTestHelper
  import Ecto.Query

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)
  @file_id "voice-file-id-1"

  @too_long_copy "El audio es muy largo. ¿Podés mandarlo en partes más cortas o escribirlo?"
  @rate_limited_copy "Recibí muchos audios en poco tiempo. ¿Me lo contás por texto por ahora?"

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

    TranscriptionStub.install(%{text: "hola", segments: [], language: "es", duration: 2.0})

    bind_patient()
  end

  describe "queue (S7)" do
    test "runs on its own :telegram_voice queue, not the session-recording :transcription queue" do
      assert TelegramVoiceNoteWorker.__opts__()[:queue] == :telegram_voice

      queues = Application.fetch_env!(:alethea, Oban)[:queues]
      assert queues[:telegram_voice] == 2
      assert queues[:transcription] == 2
    end

    test "the message worker enqueues the voice job on :telegram_voice" do
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: voice_args(800, 90)})

      assert_enqueued(worker: TelegramVoiceNoteWorker, queue: :telegram_voice)
    end
  end

  describe "size cap before download (S7)" do
    test "a file_size above the cap is neither downloaded nor transcribed" do
      args = voice_args(801, 91, file_size: 20 * 1024 * 1024 + 1)

      assert :ok = run_voice_note(args)

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@too_long_copy)
    end

    test "a note without duration is bounded by its file_size: within the cap it is transcribed" do
      assert :ok = run_voice_note(voice_args(802, 92, duration: nil, file_size: 4_096))

      assert Fake.downloads() == [@file_id]
      assert_received {:transcription_stub_called, _audio, _opts}
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"
    end

    test "a note without duration and above the size cap is not downloaded" do
      assert :ok = run_voice_note(voice_args(803, 93, duration: nil, file_size: 25_000_000))

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@too_long_copy)
    end

    test "a note with neither duration nor file_size is not downloaded" do
      assert :ok = run_voice_note(voice_args(804, 94, duration: nil))

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@too_long_copy)
    end

    test "downloaded bytes above the cap never reach the provider" do
      put_voice_config(max_file_bytes: 4)

      # The Fake download returns more than 4 bytes; the declared size lies.
      assert :ok = run_voice_note(voice_args(805, 95, file_size: 3))

      assert Fake.downloads() == [@file_id]
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@too_long_copy)
    end
  end

  describe "per-patient rate cap (S7)" do
    test "a note over the patient's cap is not downloaded and gets the rate-limit copy",
         %{foundation_patient: patient} do
      put_voice_config(max_notes_per_window: 2)

      insert_voice_job(810, 100, patient.id)
      insert_voice_job(811, 101, patient.id)
      over_cap = insert_voice_job(812, 102, patient.id)

      assert :ok = perform_persisted(over_cap)

      assert Fake.downloads() == []
      refute_received {:transcription_stub_called, _, _}
      assert_only_notice(@rate_limited_copy)
    end

    test "a note within the cap is transcribed", %{foundation_patient: patient} do
      put_voice_config(max_notes_per_window: 2)

      insert_voice_job(813, 103, patient.id)
      within_cap = insert_voice_job(814, 104, patient.id)

      assert :ok = perform_persisted(within_cap)

      assert Fake.downloads() == [@file_id]
      assert_received {:transcription_stub_called, _audio, _opts}
    end

    test "another patient's notes do not count toward the cap", %{foundation_patient: patient} do
      put_voice_config(max_notes_per_window: 2)

      other_patient_id = Ecto.UUID.generate()
      insert_voice_job(815, 105, other_patient_id)
      insert_voice_job(816, 106, other_patient_id)
      own = insert_voice_job(817, 107, patient.id)

      assert :ok = perform_persisted(own)

      assert Fake.downloads() == [@file_id]
      assert_received {:transcription_stub_called, _audio, _opts}
    end

    test "notes older than the window do not count", %{foundation_patient: patient} do
      put_voice_config(max_notes_per_window: 1)

      old = insert_voice_job(818, 108, patient.id)
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7_200, :second)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^old.id),
        set: [inserted_at: two_hours_ago]
      )

      recent = insert_voice_job(819, 109, patient.id)

      assert :ok = perform_persisted(recent)

      assert Fake.downloads() == [@file_id]
    end
  end

  describe "sealed args (S4)" do
    test "the message worker enqueues the voice job with patient_id in clear and the message sealed",
         %{foundation_patient: patient} do
      assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: voice_args(820, 110)})

      [job] = all_enqueued(worker: TelegramVoiceNoteWorker)
      raw_args = Jason.encode!(job.args)

      assert job.args["patient_id"] == patient.id
      assert job.args["telegram_update_id"] == 820
      refute Map.has_key?(job.args, "message")
      refute raw_args =~ to_string(@chat_id)
      refute raw_args =~ @file_id
      assert %{"voice" => %{"file_id" => @file_id}} = JobPayload.fetch!(job.args, :message)
    end

    test "a sealed voice job reloaded from the DB is transcribed", %{foundation_patient: patient} do
      job = insert_voice_job(821, 111, patient.id)

      assert :ok = perform_persisted(job)

      assert Fake.downloads() == [@file_id]
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"
    end

    test "a legacy voice job (plaintext message, no patient_id) is still transcribed" do
      legacy_args = voice_args(822, 112) |> Jason.encode!() |> Jason.decode!()

      assert %{"message" => %{"voice" => _}} = legacy_args
      assert :ok = run_voice_note(legacy_args)

      assert Fake.downloads() == [@file_id]
      assert Repo.one!(from m in Message, where: m.direction == "inbound").media_type == "voice"
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp put_voice_config(overrides) do
    previous = Application.get_env(:alethea, TelegramVoiceNoteWorker, [])
    Application.put_env(:alethea, TelegramVoiceNoteWorker, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:alethea, TelegramVoiceNoteWorker, previous) end)
  end

  defp run_voice_note(args) do
    TelegramVoiceNoteWorker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 3})
  end

  defp insert_voice_job(update_id, message_id, patient_id) do
    update_id
    |> voice_args(message_id)
    |> Map.put("patient_id", patient_id)
    |> TelegramVoiceNoteWorker.new()
    |> Oban.insert!()
  end

  defp perform_persisted(%Oban.Job{id: id}) do
    TelegramVoiceNoteWorker.perform(Repo.get!(Oban.Job, id))
  end

  defp assert_only_notice(copy) do
    assert [job] = all_enqueued(worker: TelegramOutboundWorker)

    assert %{"body" => ^copy, "chat_id_hash" => @chat_id_hash, "message_id" => nil} =
             JobPayload.open_fields(job.args)

    assert Repo.aggregate(Message, :count, :id) == 0
  end

  defp voice_args(update_id, message_id, opts \\ []) do
    voice =
      %{"file_id" => @file_id, "mime_type" => "audio/ogg"}
      |> put_if_present("duration", Keyword.get(opts, :duration, 5))
      |> put_if_present("file_size", Keyword.get(opts, :file_size))

    %{
      "telegram_update_id" => update_id,
      "message" => %{
        "message_id" => message_id,
        "date" => 1_700_000_000,
        "chat" => %{"id" => @chat_id, "type" => "private"},
        "voice" => voice
      }
    }
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

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
