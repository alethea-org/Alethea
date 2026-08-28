defmodule Mix.Tasks.Alethea.Demo.ResetTest do
  use Alethea.DataCase, async: false

  import ExUnit.CaptureIO

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Foundation.Accounts.BotConfig

  @target_tables ~w(
    ai_diagnoses
    audit_logs
    clinical_notes
    clinical_sessions
    clinical_summaries
    clinical_trends
    emotion_analyses
    encryption_keys
    foundation_admins
    foundation_outbound_dead_letters
    foundation_patient_auth_codes
    foundation_patients
    foundation_professionals
    messages
    oban_jobs
    patients
    professionals
    target_behaviors
  )

  test "fails closed outside development" do
    professional = insert_legacy_professional!()

    assert_raise Mix.Error, "ALETHEA_DEMO_RESET_FAILED reason=development_only", fn ->
      capture_io(:stderr, fn -> run_task(["--confirm"], :test) end)
    end

    assert Repo.get!(Professional, professional.id)
  end

  test "requires explicit confirmation" do
    professional = insert_legacy_professional!()

    assert_raise Mix.Error, "usage: mix alethea.demo.reset --confirm", fn ->
      capture_io(:stderr, fn -> run_task([], :dev) end)
    end

    assert Repo.get!(Professional, professional.id)
  end

  test "cleans all demo tables while preserving BotConfig exactly" do
    seed_all_categories!()
    bot_config_before = raw_bot_configs()

    output = capture_io(fn -> run_task(["--confirm"], :dev) end)

    assert output =~
             ~r/^ALETHEA_DEMO_RESET_COMPLETE jobs=\d+ delivery=\d+ clinical=\d+ foundation_accounts=\d+ legacy_accounts=\d+ bot_configs_preserved=1\n$/

    assert Enum.all?(@target_tables, &(table_count(&1) == 0))
    assert raw_bot_configs() == bot_config_before
  end

  test "rolls back every deletion when any delete fails" do
    %{professional: professional} = seed_all_categories!()
    bot_config_before = raw_bot_configs()

    Repo.query!("""
    CREATE TABLE demo_reset_blockers (
      professional_id uuid PRIMARY KEY REFERENCES professionals(id)
    )
    """)

    Repo.query!("INSERT INTO demo_reset_blockers (professional_id) VALUES ($1::text::uuid)", [
      professional.id
    ])

    assert_raise Mix.Error, "ALETHEA_DEMO_RESET_FAILED reason=transaction_failed", fn ->
      capture_io(:stderr, fn -> run_task(["--confirm"], :dev) end)
    end

    assert Enum.all?(@target_tables, &(table_count(&1) > 0))
    assert raw_bot_configs() == bot_config_before
  end

  defp seed_all_categories! do
    professional = insert_legacy_professional!()
    {:ok, kek} = Accounts.load_professional_kek(professional)

    {:ok, patient} =
      Accounts.create_patient(
        %{alias: "Reset Patient", professional_id: professional.id, terms_accepted: true},
        kek
      )

    now = DateTime.utc_now(:second)

    session =
      Repo.insert!(%Alethea.Clinical.Session{
        patient_id: patient.id,
        started_at: now,
        status: "open"
      })

    message =
      Repo.insert!(%Alethea.Clinical.Message{
        patient_id: patient.id,
        session_id: session.id,
        direction: "inbound",
        behavior_type: "spontaneous",
        encrypted_content: <<1, 2, 3>>,
        timestamp: now
      })

    Repo.insert!(%Alethea.AI.Diagnosis{
      message_id: message.id,
      model_version: "test",
      extracted_emotions: %{},
      ai_response: "synthetic"
    })

    Repo.insert!(%Alethea.Clinical.EmotionAnalysis{
      message_id: message.id,
      joy_score: 1.0,
      sadness_score: 0.0,
      anger_score: 0.0,
      fear_score: 0.0,
      neutral_score: 0.0,
      dominant_label: "joy",
      confidence: 1.0,
      processed_at: now
    })

    Repo.insert!(%Alethea.Clinical.Summary{
      patient_id: patient.id,
      period_start: now,
      period_end: now,
      summary_text: "synthetic",
      status_level: "stable",
      type: "session"
    })

    Repo.insert!(%Alethea.Clinical.Trend{
      patient_id: patient.id,
      indicator_name: "synthetic",
      score: 1.0,
      delta: 0.0,
      recorded_at: now
    })

    Repo.insert!(%Alethea.Accounts.AuditLog{
      professional_id: professional.id,
      action: "synthetic",
      resource_type: "Patient"
    })

    # sdd/clinical-record-foundation (#194, PR1): these two tables carry a
    # `professional_id` FK with `on_delete: :restrict`, so this reset must
    # delete them explicitly rather than rely on any cascade — this seed
    # proves the fix in `Mix.Tasks.Alethea.Demo.Reset` (@delete_groups
    # `clinical` group + @lock_tables) covers both new tables.
    Repo.insert!(%Alethea.ClinicalRecord.TargetBehavior{
      patient_id: patient.id,
      professional_id: professional.id,
      encrypted_description: <<1, 2, 3>>
    })

    Repo.insert!(%Alethea.ClinicalRecord.ClinicalNote{
      patient_id: patient.id,
      professional_id: professional.id,
      encrypted_body: <<1, 2, 3>>
    })

    {:ok, foundation_professional} =
      FoundationAccounts.register_professional(%{
        email: "reset-foundation@example.com",
        password: "securepassword123",
        full_name: "Reset Foundation Professional"
      })

    {:ok, foundation_patient} =
      FoundationAccounts.create_patient(foundation_professional, %{
        alias: "Reset Foundation Patient",
        legacy_patient_id: patient.id,
        telegram_chat_id_hash: String.duplicate("a", 64)
      })

    {:ok, _auth_code} =
      FoundationAccounts.create_patient_auth_code(foundation_patient.id, kind: "deep_link")

    {:ok, _admin} =
      FoundationAccounts.register_admin(%{
        email: "reset-admin@example.com",
        password: "securepassword123",
        role: "support"
      })

    Repo.insert!(%Alethea.Foundation.Accounts.OutboundDeadLetter{
      patient_id: foundation_patient.id,
      chat_id_hash: String.duplicate("a", 64),
      text: "synthetic",
      last_error: "synthetic",
      attempts: 1,
      failed_at: now,
      lane: "safe"
    })

    {:ok, _job} =
      %{patient_id: patient.id}
      |> Alethea.Jobs.TelegramMessageWorker.new()
      |> Oban.insert()

    {:ok, _bot_config} =
      BotConfig.upsert(%{
        env: "test",
        bot_token: "synthetic-bot-token",
        secret_token: "synthetic-webhook-secret",
        bot_username: "alethea_synthetic_bot"
      })

    %{professional: professional}
  end

  defp insert_legacy_professional! do
    {:ok, professional} =
      Accounts.create_professional(%{
        email: "reset-#{System.unique_integer([:positive])}@example.com",
        password: "securepassword123",
        full_name: "Reset Professional"
      })

    professional
  end

  defp raw_bot_configs do
    Repo.query!(
      "SELECT id, env, token_ciphertext, bot_username, secret_token_ciphertext, inserted_at, updated_at FROM foundation_bot_configs ORDER BY id"
    ).rows
  end

  defp table_count(table) do
    Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()
  end

  defp run_task(args, env) do
    Mix.Task.reenable("alethea.demo.reset")
    Mix.Tasks.Alethea.Demo.Reset.run(args, env)
  end
end
