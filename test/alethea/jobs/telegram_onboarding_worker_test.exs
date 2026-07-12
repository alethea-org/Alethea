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
  # REQ-W-welcome-text-resolution / REQ-W-name-interpolation /
  # REQ-W-preload-professional
  # ----------------------------------------------------------------

  describe "perform/1 — welcome copy resolved from the professional's custom message" do
    test "uses the professional's custom welcome_message with %{name} interpolated" do
      professional = professional_fixture()
      patient = patient_fixture(professional, %{profile_name: "Ana Gómez"})
      bind_patient_to_legacy_professional(patient, "¡Hola %{name}! Este es tu espacio seguro.")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "¡Hola Ana! Este es tu espacio seguro."
    end

    test "returns the professional's custom message verbatim when it has no %{name} placeholder" do
      professional = professional_fixture()
      patient = patient_fixture(professional, %{profile_name: "Ana Gómez"})
      bind_patient_to_legacy_professional(patient, "Bienvenido a tu espacio.")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "Bienvenido a tu espacio."
    end

    test "falls back to the system default when the professional's welcome_message is nil" do
      professional = professional_fixture()
      patient = patient_fixture(professional, %{profile_name: "Ana Gómez"})
      bind_patient_to_legacy_professional(patient, nil)

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)

      assert outbound_job.args["body"] ==
               "¡Hola, Ana! Tu cuenta de Telegram fue vinculada correctamente. " <>
                 "A partir de ahora podés escribirme por acá."
    end

    test "collapses the %{name} gap to a single space when the patient has no first name" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "Hola %{name} bienvenido.")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "Hola bienvenido."
    end

    test "collapses multiple %{name} occurrences with no known patient name and leaves no double/triple spaces" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "Hola %{name}, ¿cómo estás %{name}?")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      # Exact-string assertion (Judgment Day Round 2): the previous
      # `refute body =~ "  "` assertions passed even when the fix left
      # an orphan space before punctuation ("Hola , ¿cómo estás ?"),
      # since a single stray space isn't a double space. Asserting the
      # full string is what actually catches that regression.
      assert outbound_job.args["body"] == "Hola, ¿cómo estás?"
    end

    test "collapses a pre-existing double space anywhere in the template when the patient has no known name" do
      # Judgment Day Round 3 (accepted trade-off, confirmed with the
      # user): earlier rounds required an unrelated double space
      # elsewhere in the template to survive untouched. Chasing every
      # possible punctuation/quote/word-boundary shape adjacent to
      # "%{name}" without ever touching whitespace elsewhere in the
      # template proved to not terminate (three rounds of new edge
      # cases). The final, simpler algorithm applies one global
      # "collapse 2+ spaces to 1" cleanup pass instead of a
      # placeholder-scoped one — deliberately accepting that a
      # professional's own pre-existing double space elsewhere also
      # gets normalized, in exchange for correctly handling every
      # placeholder-adjacency shape found across all three rounds.
      professional = professional_fixture()
      patient = patient_fixture(professional)

      bind_patient_to_legacy_professional(
        patient,
        "Bienvenido!!  Espero que estés bien %{name}."
      )

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)

      assert outbound_job.args["body"] == "Bienvenido!! Espero que estés bien."
    end

    test "a %{name} placeholder directly adjacent to punctuation leaves no orphan space" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "Bienvenido %{name}!")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "Bienvenido!"
    end

    test "a %{name} placeholder adjacent to a non-punctuation character (quotes, parens, mid-word) leaves no orphan space" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "Hola \"%{name}\" (bienvenido)")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "Hola \"\" (bienvenido)"
    end

    # Judgment Day Round 3 (CRITICAL, both judges): a template made up
    # of ONLY the placeholder collapsed to an empty outbound Telegram
    # message when the patient's name was unknown.
    test "a template that is only the %{name} placeholder falls back to the system default, not an empty message" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "%{name}")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)

      # Exact-string assertion (Judgment Day Round 4, both judges): a
      # substring/refute check would still pass on a garbled fallback.
      assert outbound_job.args["body"] ==
               "¡Hola! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."
    end

    # Judgment Day Round 4 (CRITICAL, one judge): a template where the
    # placeholder is the only "content" but surrounded by punctuation
    # (e.g. "%{name}!") isn't the literal empty string once removed
    # ("!" survives), so the old `result == ""` fallback guard missed
    # it and shipped a patient a message that was just punctuation.
    test "a template that collapses to only punctuation falls back to the system default" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "%{name}!")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)

      assert outbound_job.args["body"] ==
               "¡Hola! Tu cuenta de Telegram fue vinculada correctamente. A partir de ahora podés escribirme por acá."
    end

    # Judgment Day Round 4 (WARNING, both judges): the global cleanup
    # regexes only matched a literal ASCII space, missing newlines/tabs
    # — a realistic gap since the dashboard's welcome_message field is
    # a plain <textarea> and the column is unbounded text.
    test "collapses whitespace around %{name} that includes newlines, not only literal spaces" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      bind_patient_to_legacy_professional(patient, "Hola\n%{name}\nBienvenido a tu espacio.")

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == "Hola Bienvenido a tu espacio."
    end

    test "does not log a warning when the patient simply has no legacy bridge yet (:not_linked)" do
      professional = professional_fixture()
      patient = patient_fixture(professional)
      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      log =
        capture_log(fn ->
          assert :ok = TelegramOnboardingWorker.perform(job)
        end)

      refute log =~ "unexpected failure resolving custom welcome_message"
    end

    # No integration test constructs the "unexpected failure" branch
    # itself (`{:error, :legacy_not_found}` or a nil-preloaded
    # `:professional`): both `foundation_patients.legacy_patient_id`
    # (`on_delete: :nilify_all`) and `patients.professional_id`
    # (`on_delete: :delete_all`, `null: false`) are real DB foreign
    # keys, so a dangling/orphaned reference cannot be produced
    # through ordinary Ecto writes — the schema's own referential
    # integrity keeps this branch defensive-only, the same way
    # `failure_text/1`'s catch-all clause is documented as
    # "currently unreachable in practice" above. The branch split
    # itself (silent for `:not_linked`, logged otherwise) is verified
    # by the "does not log" test above staying green together with
    # the code review of `custom_welcome_message/1`.

    test "an empty-string welcome_message is sent verbatim, not falling back to the default" do
      # This state is NOT reachable through the real dashboard save
      # path: Ecto.Changeset.cast/4's default empty_values: [""]
      # normalizes "" to nil before Professional.changeset/2 ever
      # applies it (verified in professional_test.exs and
      # design.md). Every OTHER test in this file uses
      # bind_patient_to_legacy_professional/2, which now goes through
      # the real Accounts.create_professional/1 path (Judgment Day
      # Round 2, JD-004) — that path cannot construct welcome_message:
      # "" at all. This one test deliberately bypasses the changeset to
      # document welcome_text/1's own `||`-based resolution in
      # isolation, in case a future write path (raw SQL, seeds) ever
      # produces a literal "".
      professional = professional_fixture()
      patient = patient_fixture(professional, %{profile_name: "Ana Gómez"})

      {:ok, legacy_professional} =
        Alethea.Accounts.create_professional(%{
          email: "legacy-pro-#{unique_int()}@test.local",
          password: "supersecret12",
          full_name: "Legacy Pro #{unique_int()}"
        })

      legacy_professional
      |> Ecto.Changeset.change(%{welcome_message: ""})
      |> Repo.update!()

      legacy_patient = insert_legacy_patient(legacy_professional, "alias-#{unique_int()}")

      patient
      |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
      |> Repo.update!()

      {:ok, auth_code} = PatientAuthCode.create_patient_auth_code(patient.id, kind: "deep_link")

      job = %Oban.Job{
        args: %{"telegram_update_id" => 1, "token" => auth_code.code, "chat_id" => @chat_id}
      }

      assert :ok = TelegramOnboardingWorker.perform(job)

      [outbound_job] = all_enqueued(worker: TelegramOutboundWorker)
      assert outbound_job.args["body"] == ""
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

  # ----------------------------------------------------------------
  # Fixtures for the legacy-professional bridge (REQ-W-preload-professional)
  #
  # `patient_fixture/2` only creates a foundation-namespace patient with
  # no `legacy_patient_id` link. `welcome_text/1` resolves the
  # dashboard-editable `welcome_message` from the LEGACY
  # `Alethea.Accounts.Professional` (the same one `DashboardLive`'s
  # `save_welcome_message` event writes to), reached via
  # `Foundation.Accounts.legacy_patient/1` — the exact bridge
  # `TelegramMessageWorker`'s crisis branch already uses for
  # `crisis_message`. These helpers wire that bridge up for a test
  # patient.
  # ----------------------------------------------------------------

  defp bind_patient_to_legacy_professional(foundation_patient, welcome_message) do
    legacy_professional = insert_legacy_professional_with_welcome_message(welcome_message)
    legacy_patient = insert_legacy_patient(legacy_professional, "alias-#{unique_int()}")

    foundation_patient
    |> Ecto.Changeset.change(%{legacy_patient_id: legacy_patient.id})
    |> Repo.update!()
  end

  defp insert_legacy_professional_with_welcome_message(welcome_message) do
    # Judgment Day Round 2 (JD-004): the previous version of this
    # fixture claimed `create_professional/1` "does not accept
    # welcome_message in the first-arg attrs" and bypassed
    # `Professional.changeset/2` via `Ecto.Changeset.change/2` +
    # `Repo.update!/1` instead. That claim was false — both
    # `create_professional/1` and `update_professional/2` cast
    # `welcome_message` through the exact same changeset (see
    # `professional_test.exs`'s "saves through a real DB round-trip"
    # test) — and bypassing it also silently skipped
    # `validate_length(:welcome_message, max: 4096)`. Passing it
    # directly in the create attrs both fixes the stale claim and
    # exercises the real, validated write path.
    {:ok, professional} =
      Alethea.Accounts.create_professional(%{
        email: "legacy-pro-#{unique_int()}@test.local",
        password: "supersecret12",
        full_name: "Legacy Pro #{unique_int()}",
        welcome_message: welcome_message
      })

    professional
  end

  defp insert_legacy_patient(professional, alias_name) do
    {:ok, kek} = Alethea.Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Alethea.Accounts.create_patient(
        %{
          "whatsapp_number" => "+5491#{:rand.uniform(99_999_999)}",
          "alias" => alias_name,
          "professional_id" => professional.id
        },
        kek
      )

    patient
  end

  defp unique_int, do: System.unique_integer([:positive])
end
