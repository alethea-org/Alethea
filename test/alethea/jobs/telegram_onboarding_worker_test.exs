defmodule Alethea.Jobs.TelegramOnboardingWorkerTest do
  @moduledoc """
  Tests for `Alethea.Jobs.TelegramOnboardingWorker` (C-4 full; PR #4 /
  TASK-4-3).

  Covers the full onboarding flow that replaces the PR #2 stub:

    - REQ-C4-bind-chat-on-success: valid token binds the chat, marks
      the auth code used, enqueues exactly one welcome message on
      `:telegram_outbound`.
    - REQ-C4-reject-expired-token / REQ-C4-reject-already-used-token /
      REQ-C4-reject-rate-limited: each failure branch sends the
      matching localized message and does NOT bind.
    - REQ-C4-reject-chat-bound-to-other-patient: a collision on
      `telegram_chat_id_hash` is rejected without consuming the code.
    - REQ-C4-six-digit-fallback ("/start" rejection half): a
      `kind: "six_digit"` code cannot be redeemed via `/start` — the
      worker always scopes its lookup to `kind: "deep_link"`.
    - REQ-C4-send-welcome-reply: exactly one outbound job, correct
      queue, patient's first name in the body.

  ## PHI hygiene (R-1)

  Tests assert (via `ExUnit.CaptureLog`) that no log line emitted by
  the worker contains the raw `chat_id` or the full `chat_id_hash` —
  only the `LogRedactor.prefix/1` 8-char correlation token.
  """

  use Alethea.DataCase, async: false
  use Oban.Testing, repo: Alethea.Repo

  import Alethea.FoundationTestHelper
  import ExUnit.CaptureLog

  alias Alethea.Foundation.Accounts.{Patient, PatientAuthCode}
  alias Alethea.Jobs.{TelegramOnboardingWorker, TelegramOutboundWorker}
  alias Alethea.Repo
  alias Alethea.Telegram.ChatIdHash

  @pepper "telegram-chat-id-pepper-v1-test-only-min-32-bytes-padding-xyz"
  @chat_id 123_456_789
  @chat_id_hash ChatIdHash.hash(@chat_id, @pepper)

  setup do
    Application.put_env(:alethea, :telegram_chat_id_pepper, @pepper)
    Repo.delete_all(Oban.Job)
    :ok
  end

  # ----------------------------------------------------------------
  # Oban.Worker contract
  # ----------------------------------------------------------------

  describe "Oban.Worker contract" do
    test "uses the :telegram_inbound queue with max_attempts: 2" do
      opts = TelegramOnboardingWorker.__opts__()
      assert opts[:queue] == :telegram_inbound
      assert opts[:max_attempts] == 2
      assert opts[:unique] in [nil, []]
    end
  end

  # ----------------------------------------------------------------
  # REQ-C4-bind-chat-on-success + REQ-C4-send-welcome-reply
  # ----------------------------------------------------------------

  describe "perform/1 — successful bind (deep_link, from /start)" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional, %{profile_name: "Ana Gómez"})
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")
      %{patient: patient, auth_code: auth_code}
    end

    test "binds the chat, consumes the code, and enqueues one welcome message", %{
      patient: patient,
      auth_code: auth_code
    } do
      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, patient.id)
      assert reloaded_patient.telegram_chat_id_hash == @chat_id_hash

      reloaded_code = Repo.get!(PatientAuthCode, auth_code.id)
      assert %DateTime{} = reloaded_code.used_at

      assert_enqueued(worker: TelegramOutboundWorker, queue: "telegram_outbound")

      [job] = all_enqueued(worker: TelegramOutboundWorker)
      assert job.args["chat_id"] == @chat_id
      assert job.args["chat_id_hash"] == @chat_id_hash
      assert job.args["body"] =~ "Ana"
      # Regression (WARNING fix): the bound patient's id must be
      # threaded onto the outbound job args — `TelegramOutboundWorker`
      # reads `patient_id` to attribute dead-letter rows / `ops:alerts`
      # broadcasts on a later delivery failure.
      assert job.args["patient_id"] == patient.id
    end

    test "does not log the raw chat_id or the full chat_id_hash", %{auth_code: auth_code} do
      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      log =
        capture_log(fn ->
          TelegramOnboardingWorker.perform(job)
        end)

      refute log =~ to_string(@chat_id)
      refute log =~ @chat_id_hash
    end
  end

  describe "perform/1 — welcome copy without a profile_name" do
    test "falls back to a generic greeting when the patient has no first name" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "vinculada"
    end
  end

  # ----------------------------------------------------------------
  # REQ-C4-reject-expired-token / already-used / rate-limited
  # ----------------------------------------------------------------

  describe "perform/1 — failure branches" do
    setup do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")
      %{patient: patient, auth_code: auth_code}
    end

    test "expired token: no bind, localized message enqueued, code untouched", %{
      patient: patient,
      auth_code: auth_code
    } do
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      auth_code
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, patient.id)
      assert reloaded_patient.telegram_chat_id_hash == nil

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "venció"
    end

    test "already-used token: no bind, localized message enqueued", %{auth_code: auth_code} do
      used_at = DateTime.utc_now() |> DateTime.truncate(:second)

      auth_code
      |> Ecto.Changeset.change(used_at: used_at)
      |> Repo.update!()

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "ya fue usado"
    end

    test "rate-limited token: no bind, localized message enqueued", %{auth_code: auth_code} do
      # The worker always verifies with the "telegram-webhook" sentinel
      # IP (no per-patient IP is available from the bot webhook — see
      # the worker's moduledoc). Pre-exhaust the rate limit using that
      # SAME sentinel so `perform/1`'s own verify call lands as the
      # blocked attempt.
      for _ <- 1..5 do
        Alethea.Foundation.Accounts.verify_patient_auth_code(auth_code.code, "telegram-webhook",
          kind: "deep_link"
        )
      end

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "intentos"
    end

    test "nil token (cold-open, no professional pre-minted link) sends a rejection reply" do
      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => nil, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["chat_id"] == @chat_id
    end
  end

  # ----------------------------------------------------------------
  # REQ-C4-reject-chat-bound-to-other-patient
  # ----------------------------------------------------------------

  describe "perform/1 — chat already bound to a different patient" do
    test "rejects the bind, leaves both patients unmodified, code stays retryable" do
      professional = professional_fixture()
      patient_a = patient_fixture(professional)
      {:ok, _} = Patient.update_patient(patient_a, %{telegram_chat_id_hash: @chat_id_hash})

      patient_b = patient_fixture(professional)

      {:ok, auth_code_b} =
        PatientAuthCode.create_patient_auth_code(patient_b.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code_b.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded_a = Repo.get!(Patient, patient_a.id)
      assert reloaded_a.telegram_chat_id_hash == @chat_id_hash

      reloaded_b = Repo.get!(Patient, patient_b.id)
      assert reloaded_b.telegram_chat_id_hash == nil

      reloaded_code_b = Repo.get!(PatientAuthCode, auth_code_b.id)
      assert reloaded_code_b.used_at == nil

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "otro paciente"
    end

    test "same patient rebinding their own chat succeeds normally" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      old_hash = String.duplicate("z", 64)
      {:ok, _} = Patient.update_patient(patient, %{telegram_chat_id_hash: old_hash})

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded = Repo.get!(Patient, patient.id)
      assert reloaded.telegram_chat_id_hash == @chat_id_hash

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] =~ "vinculada"
    end
  end

  # ----------------------------------------------------------------
  # REQ-C4-six-digit-fallback — six_digit codes cannot be redeemed via /start
  # ----------------------------------------------------------------

  describe "perform/1 — six_digit code submitted via /start is rejected" do
    test "no chat binding occurs and the six_digit code's used_at is not mutated" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, six_digit} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "six_digit")

      # The webhook controller always enqueues onboarding jobs without an
      # explicit `kind` (defaults to "deep_link" in the worker) — a
      # patient typing `/start <6-digit code>` is indistinguishable from
      # a garbled deep-link token at this layer, and the kind-scoped
      # lookup naturally rejects it.
      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => six_digit.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      reloaded_patient = Repo.get!(Patient, patient.id)
      assert reloaded_patient.telegram_chat_id_hash == nil

      reloaded_code = Repo.get!(PatientAuthCode, six_digit.id)
      assert reloaded_code.used_at == nil
    end
  end
end
