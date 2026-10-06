defmodule Alethea.Jobs.TelegramMessageWorkerGuardrailsTest do
  @moduledoc """
  Behavior tests for the guarded journaling reply (#392), driven through
  `Alethea.Jobs.TelegramMessageWorker.perform/1` with the AI worker
  boundary (`Alethea.AI.PhiWorkerMock`) controlled.

  What the model is supplied with is asserted on the payload that reaches
  the mocked boundary; what the patient would receive is asserted on the
  persisted outbound `Message` and the enqueued `TelegramOutboundWorker`
  job. No live model or classifier is involved.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo
  import Mox
  import Ecto.Query
  import Alethea.FoundationTestHelper

  alias Alethea.Clinical
  alias Alethea.Clinical.Message
  alias Alethea.Jobs.TelegramMessageWorker
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash
  alias AletheaJobs.EmotionAnalysisWorker

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 392_392_392
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  # Far enough in the past that every seeded turn precedes the inbound
  # the worker persists during the test.
  @conversation_start ~U[2026-01-10 15:00:00Z]

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)

    setup_bound_patient()
  end

  setup :verify_on_exit!

  describe "perform/1 — conversation history supplied to the model" do
    test "supplies prior turns chronologically with explicit patient and Alethea roles", ctx do
      seed_turn(ctx, "inbound", "Hoy discutí con mi hermana.", 0)
      seed_turn(ctx, "outbound", "Gracias por contarlo. ¿Qué pasó después?", 60)
      seed_turn(ctx, "inbound", "Me fui a mi cuarto sin decir nada.", 120)

      payload = perform_capturing_payload("Todavía sigo pensando en eso.", 1)

      assert payload.history == [
               %{role: :patient, content: "Hoy discutí con mi hermana."},
               %{role: :alethea, content: "Gracias por contarlo. ¿Qué pasó después?"},
               %{role: :patient, content: "Me fui a mi cuarto sin decir nada."}
             ]
    end

    test "supplies the current turn once, outside the history", ctx do
      seed_turn(ctx, "inbound", "Ayer no dormí bien.", 0)

      payload = perform_capturing_payload("Hoy tampoco pude descansar.", 2)

      assert payload.sanitized_content == "Hoy tampoco pude descansar."
      assert payload.history == [%{role: :patient, content: "Ayer no dormí bien."}]
    end

    test "bounds the history to the 10 most recent prior messages", ctx do
      for n <- 1..12 do
        direction = if rem(n, 2) == 1, do: "inbound", else: "outbound"
        seed_turn(ctx, direction, "mensaje #{n}", n * 60)
      end

      payload = perform_capturing_payload("mensaje actual", 3)

      assert Enum.map(payload.history, & &1.content) == Enum.map(3..12, &"mensaje #{&1}")
    end

    test "orders turns persisted within the same second deterministically, patient first",
         ctx do
      # Seeded Alethea-first so insertion order cannot explain the result.
      seed_turn(ctx, "outbound", "¿Cómo te sentiste en ese momento?", 0)
      seed_turn(ctx, "inbound", "Tuve una reunión difícil.", 0)

      first = perform_capturing_payload("Me sentí ignorado.", 4)
      second = perform_capturing_payload("Y después me quedé callado.", 5)

      expected = [
        %{role: :patient, content: "Tuve una reunión difícil."},
        %{role: :alethea, content: "¿Cómo te sentiste en ese momento?"}
      ]

      assert first.history == expected
      assert Enum.take(second.history, 2) == expected
    end

    test "starts with an empty history for a patient's first message" do
      payload = perform_capturing_payload("Hola, es mi primer registro.", 6)

      assert payload.history == []
    end
  end

  describe "perform/1 — sanitization of everything supplied to the model" do
    test "redacts identifiers from prior turns as well as from the current turn", ctx do
      seed_turn(ctx, "inbound", "Mi correo es ana.perez@example.com por si acaso.", 0)
      seed_turn(ctx, "outbound", "Anotado. ¿Qué te gustaría registrar hoy?", 60)

      payload =
        perform_capturing_payload("Le escribí a jefe@empresa.cl y no me respondió.", 7)

      supplied = Enum.map_join(payload.history, "\n", & &1.content) <> payload.sanitized_content

      refute supplied =~ "ana.perez@example.com"
      refute supplied =~ "jefe@empresa.cl"
      assert hd(payload.history).content == "Mi correo es [REDACTED_EMAIL] por si acaso."
      assert payload.sanitized_content == "Le escribí a [REDACTED_EMAIL] y no me respondió."
    end

    test "supplies only the message id, the current turn and the history — no inferred clinical data",
         ctx do
      seed_turn(ctx, "inbound", "Estuve triste toda la semana.", 0)

      payload = perform_capturing_payload("Hoy me siento parecido.", 8)

      assert payload |> Map.keys() |> Enum.sort() == [:history, :message_id, :sanitized_content]
      assert Enum.all?(payload.history, &(Map.keys(&1) |> Enum.sort() == [:content, :role]))
    end
  end

  describe "perform/1 — sentiment pipeline regression" do
    test "the inbound message is still handed to emotion analysis and anchors the model call" do
      payload = perform_capturing_payload("Hoy fue un día pesado.", 9)

      inbound = Repo.one!(from m in Message, where: m.direction == "inbound")

      assert payload.message_id == inbound.id
      assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: inbound.id})
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # Runs the worker for one inbound text and returns the payload that
  # reached the AI worker boundary.
  defp perform_capturing_payload(text, n) do
    test_pid = self()

    expect(Alethea.AI.PhiWorkerMock, :process, fn payload ->
      send(test_pid, {:ai_worker_payload, payload})
      {:ok, ai_result(payload.message_id, "Gracias por contarlo. ¿Cómo lo viviste?")}
    end)

    assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: build_args(text, n)})
    assert_receive {:ai_worker_payload, payload}
    payload
  end

  defp ai_result(message_id, response) do
    %{
      response: response,
      source_message_id: message_id,
      model_version: "phi-4-mini",
      behavior_type: :elicited
    }
  end

  # Persists a prior conversation turn through the production write
  # path, then pins its timestamp `offset_seconds` after the
  # conversation start so ordering is under the test's control.
  defp seed_turn(ctx, direction, text, offset_seconds) do
    behavior_type = if direction == "inbound", do: "spontaneous", else: "elicited"

    {:ok, message} =
      Clinical.save_telegram_message(ctx.foundation_patient, text, direction, behavior_type, nil)

    timestamp = DateTime.add(@conversation_start, offset_seconds, :second)
    Repo.update_all(from(m in Message, where: m.id == ^message.id), set: [timestamp: timestamp])

    message
  end

  defp build_args(text, n) do
    %{
      "telegram_update_id" => 39_200 + n,
      "message" => %{
        "message_id" => 39_200 + n,
        "date" => 1_700_000_000,
        "chat" => %{"id" => @chat_id, "type" => "private"},
        "text" => text
      }
    }
  end

  defp setup_bound_patient do
    foundation_patient = patient_fixture(professional_fixture(), %{alias: "Pat#{unique_int()}"})

    {:ok, legacy_professional} =
      Alethea.Accounts.create_professional(%{
        email: "pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Test Pro #{unique_int()}"
      })

    {:ok, kek} = Alethea.Accounts.load_professional_kek(legacy_professional)

    {:ok, legacy_patient} =
      Alethea.Accounts.create_patient(
        %{"alias" => "alias-#{unique_int()}", "professional_id" => legacy_professional.id},
        kek
      )

    foundation_patient =
      foundation_patient
      |> Ecto.Changeset.change(%{
        telegram_chat_id_hash: @chat_id_hash,
        legacy_patient_id: legacy_patient.id
      })
      |> Repo.update!()

    [foundation_patient: foundation_patient, legacy_patient: legacy_patient]
  end

  defp unique_int, do: System.unique_integer([:positive])
end
