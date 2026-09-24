# Seeds one professional (plus one synthetic patient) per repository collaborator
# for the shared development database. Idempotent: existing accounts are skipped.
#
#     mix run priv/repo/seeds_team.exs
#
# Development only. Emails are fictitious; never use this with real data.

alias Alethea.Accounts

if Mix.env() != :dev do
  raise "seeds_team.exs is development-only (current env: #{Mix.env()})"
end

password = "aletheaorg123"

team = [
  {"teofurlan", "Teo Furlan"},
  {"eveernst", "Evelyn Ernst"},
  {"huajar", "Rodrigo Huajamaita"},
  {"vicenzogiordana", "Vicenzo Giordana"},
  {"demianfrick", "Demian Frick"}
]

Alethea.Operator.TaskRuntime.with_services(fn ->
  Enum.each(team, fn {login, full_name} ->
    email = "#{login}@alethea.dev"

    professional =
      case Accounts.get_professional_by_email(email) do
        nil ->
          {:ok, professional} =
            Accounts.create_professional(%{
              email: email,
              full_name: full_name,
              password: password
            })

          IO.puts("  ✓ professional #{email}")
          professional

        professional ->
          IO.puts("  · professional #{email} already exists")
          professional
      end

    case Accounts.list_patients(professional.id) do
      [] ->
        {:ok, kek} = Accounts.load_professional_kek(professional)

        {:ok, patient} =
          Accounts.create_patient(
            %{alias: "Paciente demo (#{login})", professional_id: professional.id},
            kek
          )

        IO.puts("    ✓ patient #{patient.alias}")

      _patients ->
        IO.puts("    · #{login} already has patients")
    end
  end)
end)
