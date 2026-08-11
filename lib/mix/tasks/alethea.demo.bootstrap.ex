defmodule Mix.Tasks.Alethea.Demo.Bootstrap do
  use Mix.Task

  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.{Patient, Professional}
  alias Alethea.Foundation.Accounts, as: FoundationAccounts
  alias Alethea.Foundation.Accounts.BotConfig
  alias Alethea.Foundation.Accounts.Patient, as: FoundationPatient
  alias Alethea.Foundation.Accounts.Professional, as: FoundationProfessional
  alias Alethea.Operator.TaskRuntime
  alias Alethea.Repo

  @shortdoc "Creates linked synthetic Telegram demo identities"

  @moduledoc """
  Creates or reuses the fixed synthetic identities needed by the Telegram demo.

  This is intentionally demo-only tooling. It does not accept identity fields and
  cannot create arbitrary professionals or patients. The fixed `.invalid` email,
  names, and aliases make the records clearly synthetic. Passing `--synthetic` is
  required as an explicit acknowledgement of that boundary.

  The task creates or reuses the required legacy and foundation professional and
  patient rows, then sets `foundation_patients.legacy_patient_id` for the existing
  clinical message pipeline. This narrow setup path is not the general production
  identity bridge. Each invocation mints a new deep-link auth code with the
  existing 10-minute TTL.

  Set a synthetic login password without putting it in shell arguments:

      export ALETHEA_DEMO_PROFESSIONAL_PASSWORD="<synthetic-password>"
      mix alethea.demo.bootstrap --synthetic --env dev

  The password must be 12 to 72 characters. Telegram bot configuration for the
  selected environment must already exist. The only task output is one stable,
  machine-readable line:

      ALETHEA_TELEGRAM_ONBOARDING_URL=https://t.me/<bot-username>?start=<auth-code>

  The URL contains a short-lived credential. Capture it without logging it and do
  not persist it after the demo.
  """

  @switches [synthetic: :boolean, env: :string]
  @valid_envs ~w(dev test prod)
  @email "demo.professional@synthetic.invalid"
  @full_name "Synthetic Demo Professional"
  @patient_alias "Synthetic Demo Patient"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    env = parse_args!(args)
    password = demo_password!()

    onboarding_url =
      TaskRuntime.with_services(fn ->
        bot_username = bot_username!(env)
        legacy_professional = legacy_professional!(password)
        legacy_patient = legacy_patient!(legacy_professional)
        foundation_professional = foundation_professional!(password)
        foundation_patient = foundation_patient!(foundation_professional, legacy_patient)
        auth_code = auth_code!(foundation_patient)

        "https://t.me/#{bot_username}?start=#{URI.encode_www_form(auth_code.code)}"
      end)

    Mix.shell().info("ALETHEA_TELEGRAM_ONBOARDING_URL=#{onboarding_url}")
  end

  defp parse_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :synthetic, false) do
          case Keyword.get(opts, :env) do
            env when env in @valid_envs -> env
            _ -> Mix.raise("usage: mix alethea.demo.bootstrap --synthetic --env dev|test|prod")
          end
        else
          Mix.raise("pass --synthetic to acknowledge demo-only synthetic data")
        end

      _ ->
        Mix.raise("usage: mix alethea.demo.bootstrap --synthetic --env dev|test|prod")
    end
  end

  defp demo_password! do
    password = System.get_env("ALETHEA_DEMO_PROFESSIONAL_PASSWORD", "")

    if String.length(password) in 12..72 do
      password
    else
      Mix.raise("ALETHEA_DEMO_PROFESSIONAL_PASSWORD must be 12 to 72 characters")
    end
  end

  defp bot_username!(env) do
    case BotConfig.for_env(env) do
      {:ok, %BotConfig{bot_username: username}} when is_binary(username) and username != "" ->
        username

      _ ->
        Mix.raise("Telegram bot configuration is missing for env=#{env}")
    end
  end

  defp legacy_professional!(password) do
    case Repo.get_by(Professional, email: @email) do
      %Professional{} = professional ->
        professional

      nil ->
        case Accounts.create_professional(%{
               email: @email,
               password: password,
               full_name: @full_name,
               welcome_message: "Welcome to the synthetic Alethea demo, %{name}."
             }) do
          {:ok, professional} -> professional
          {:error, _reason} -> Mix.raise("Could not create the synthetic legacy professional")
        end
    end
  end

  defp legacy_patient!(professional) do
    query =
      from patient in Patient,
        where: patient.professional_id == ^professional.id and patient.alias == ^@patient_alias

    case Repo.one(query) do
      %Patient{} = patient ->
        patient

      nil ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, patient} <-
               Accounts.create_patient(
                 %{
                   alias: @patient_alias,
                   professional_id: professional.id,
                   terms_accepted: true
                 },
                 kek
               ) do
          patient
        else
          _ -> Mix.raise("Could not create the synthetic legacy patient")
        end
    end
  end

  defp foundation_professional!(password) do
    case Repo.get_by(FoundationProfessional, email: @email) do
      %FoundationProfessional{} = professional ->
        professional

      nil ->
        case FoundationAccounts.register_professional(%{
               email: @email,
               password: password,
               full_name: @full_name
             }) do
          {:ok, professional} -> professional
          {:error, _reason} -> Mix.raise("Could not create the synthetic foundation professional")
        end
    end
  end

  defp foundation_patient!(professional, legacy_patient) do
    query =
      from patient in FoundationPatient,
        where: patient.professional_id == ^professional.id and patient.alias == ^@patient_alias

    case Repo.one(query) do
      %FoundationPatient{legacy_patient_id: legacy_id} = patient
      when legacy_id == legacy_patient.id ->
        patient

      %FoundationPatient{} = patient ->
        case FoundationAccounts.update_patient(patient, %{legacy_patient_id: legacy_patient.id}) do
          {:ok, linked_patient} -> linked_patient
          {:error, _reason} -> Mix.raise("Could not link the synthetic foundation patient")
        end

      nil ->
        case FoundationAccounts.create_patient(professional, %{
               alias: @patient_alias,
               legacy_patient_id: legacy_patient.id,
               profile_name: @patient_alias,
               profile_language: "en"
             }) do
          {:ok, patient} -> patient
          {:error, _reason} -> Mix.raise("Could not create the synthetic foundation patient")
        end
    end
  end

  defp auth_code!(patient) do
    case FoundationAccounts.create_patient_auth_code(patient.id, kind: "deep_link") do
      {:ok, auth_code} -> auth_code
      {:error, _reason} -> Mix.raise("Could not mint the synthetic Telegram onboarding code")
    end
  end
end
