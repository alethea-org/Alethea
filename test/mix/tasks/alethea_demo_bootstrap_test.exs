defmodule Mix.Tasks.Alethea.Demo.BootstrapTest do
  use Alethea.DataCase, async: false

  import ExUnit.CaptureIO

  alias Alethea.Accounts.{Patient, Professional}
  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Foundation.Accounts.PatientAuthCode
  alias Alethea.Foundation.Accounts.Professional, as: FoundationProfessional

  @email "demo.professional@synthetic.invalid"
  @patient_alias "Synthetic Demo Patient"
  @password "synthetic-demo-password"

  setup do
    previous_password = System.get_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD")
    System.put_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD", @password)

    {:ok, _} =
      BotConfig.upsert(%{
        env: "test",
        bot_token: "synthetic-bot-token",
        secret_token: "synthetic-webhook-secret",
        bot_username: "alethea_synthetic_bot"
      })

    on_exit(fn ->
      if previous_password do
        System.put_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD", previous_password)
      else
        System.delete_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD")
      end
    end)

    :ok
  end

  test "requires explicit acknowledgement that all demo identities are synthetic" do
    assert_raise Mix.Error, "pass --synthetic to acknowledge demo-only synthetic data", fn ->
      capture_io(:stderr, fn -> run_task(["--env", "test"]) end)
    end

    refute Repo.get_by(Professional, email: @email)
    refute Repo.get_by(FoundationProfessional, email: @email)
  end

  test "creates linked legacy and foundation records and emits one stable auth URL line" do
    output = capture_io(fn -> run_task(["--synthetic", "--env", "test"]) end)

    legacy_professional = Repo.get_by!(Professional, email: @email)

    legacy_patient =
      Repo.get_by!(Patient,
        professional_id: legacy_professional.id,
        alias: @patient_alias
      )

    foundation_professional = Repo.get_by!(FoundationProfessional, email: @email)

    foundation_patient =
      Repo.get_by!(FoundationPatient,
        professional_id: foundation_professional.id,
        alias: @patient_alias
      )

    assert foundation_patient.legacy_patient_id == legacy_patient.id

    [url_line] = output_lines(output, "ALETHEA_TELEGRAM_ONBOARDING_URL=")
    assert url_line =~ "https://t.me/alethea_synthetic_bot?start="

    code =
      String.replace_prefix(
        url_line,
        "ALETHEA_TELEGRAM_ONBOARDING_URL=https://t.me/alethea_synthetic_bot?start=",
        ""
      )

    auth_code = Repo.get_by!(PatientAuthCode, code: code, kind: "deep_link")

    assert auth_code.patient_id == foundation_patient.id
    assert DateTime.diff(auth_code.expires_at, DateTime.utc_now(), :second) in 590..600
    refute output =~ @password
  end

  test "reuses all synthetic identity records while minting a fresh short-lived link" do
    first_output = capture_io(fn -> run_task(["--synthetic", "--env", "test"]) end)
    second_output = capture_io(fn -> run_task(["--synthetic", "--env", "test"]) end)

    assert Repo.aggregate(from(p in Professional, where: p.email == @email), :count) == 1

    assert Repo.aggregate(from(p in FoundationProfessional, where: p.email == @email), :count) ==
             1

    legacy_professional = Repo.get_by!(Professional, email: @email)
    foundation_professional = Repo.get_by!(FoundationProfessional, email: @email)

    assert Repo.aggregate(
             from(p in Patient,
               where: p.professional_id == ^legacy_professional.id and p.alias == ^@patient_alias
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(p in FoundationPatient,
               where:
                 p.professional_id == ^foundation_professional.id and p.alias == ^@patient_alias
             ),
             :count
           ) == 1

    [first_url] = output_lines(first_output, "ALETHEA_TELEGRAM_ONBOARDING_URL=")
    [second_url] = output_lines(second_output, "ALETHEA_TELEGRAM_ONBOARDING_URL=")
    refute first_url == second_url
  end

  test "validates the demo password and configured bot username" do
    System.put_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD", "short")

    assert_raise Mix.Error,
                 "ALETHEA_DEMO_PROFESSIONAL_PASSWORD must be 12 to 72 characters",
                 fn ->
                   capture_io(:stderr, fn -> run_task(["--synthetic", "--env", "test"]) end)
                 end

    System.put_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD", @password)
    Repo.delete_all(BotConfig)

    assert_raise Mix.Error, "Telegram bot configuration is missing for env=test", fn ->
      capture_io(:stderr, fn -> run_task(["--synthetic", "--env", "test"]) end)
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("alethea.demo.bootstrap")
    Mix.Tasks.Alethea.Demo.Bootstrap.run(args)
  end

  defp output_lines(output, prefix) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end
end
