# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Alethea.Repo.insert!(%Alethea.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Dev-only: idempotently create one synthetic demo professional with one
# linked patient, so a developer has a real login for the dashboard while
# `use_mock_data: true` renders the rest of the clinical data. The fixed
# `.invalid` email and clearly-labeled names make the records obviously
# synthetic. Never runs in :test or :prod.
if Mix.env() == :dev do
  import Ecto.Query

  alias Alethea.Accounts
  alias Alethea.Accounts.{Patient, Professional}
  alias Alethea.Repo

  email = "demo.mock@alethea.invalid"
  full_name = "Demo Professional (mock data)"
  patient_alias = "Paciente Demo (mock data)"
  password = System.get_env("ALETHEA_SEED_PROFESSIONAL_PASSWORD", "alethea-demo-mock-2026")

  professional =
    case Repo.get_by(Professional, email: email) do
      %Professional{} = professional ->
        professional

      nil ->
        case Accounts.create_professional(%{
               email: email,
               password: password,
               full_name: full_name,
               welcome_message: "Welcome to the Alethea demo dashboard, %{name}."
             }) do
          {:ok, professional} ->
            professional

          {:error, changeset} ->
            raise "Could not create the demo professional: #{inspect(changeset.errors)}"
        end
    end

  patient_query =
    from patient in Patient,
      where: patient.professional_id == ^professional.id and patient.alias == ^patient_alias

  case Repo.one(patient_query) do
    %Patient{} ->
      :ok

    nil ->
      with {:ok, kek} <- Accounts.load_professional_kek(professional),
           {:ok, _patient} <-
             Accounts.create_patient(
               %{
                 alias: patient_alias,
                 professional_id: professional.id,
                 terms_accepted: true
               },
               kek
             ) do
        :ok
      else
        _ -> raise "Could not create the demo patient"
      end
  end

  Mix.shell().info("""
  Demo login seeded (dev, mock data):
    email:    #{email}
    password: #{password}
  """)
end
