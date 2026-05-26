defmodule Alethea.Clinical.SessionManager do
  import Ecto.Query
  alias Alethea.Repo
  alias Alethea.Clinical.Session

  def open_session(patient) do
    %Session{}
    |> Session.changeset(%{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "open",
      patient_id: patient.id
    })
    |> Repo.insert()
  end

  def close_session(session) do
    session
    |> Session.changeset(%{
      closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "closed"
    })
    |> Repo.update()
  end

  def current_open_session(patient_id) do
    case Repo.one(
           from s in Session,
           where: s.patient_id == ^patient_id and s.status == "open",
           limit: 1
         ) do
      nil -> create_open_session(patient_id)
      session -> {:ok, session}
    end
  end

  defp create_open_session(patient_id) do
    %Session{}
    |> Session.changeset(%{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "open",
      patient_id: patient_id
    })
    |> Repo.insert()
  end
end
