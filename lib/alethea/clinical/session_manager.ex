defmodule Alethea.Clinical.SessionManager do
  import Ecto.Query
  alias Alethea.Repo
  alias Alethea.Clinical.Session

  @doc """
  Get the current open session for a patient, creating one if none exists.
  Uses PostgreSQL advisory lock to prevent race conditions.

  Returns {:ok, session} or {:error, reason}.
  """
  def current_open_session(patient_id) do
    Repo.transaction(fn ->
      # Use PostgreSQL advisory lock to serialize concurrent access for same patient
      # The lock key is derived from patient_id to ensure same patient gets same lock
      lock_key = :erlang.phash2(patient_id)

      Repo.query!("SELECT pg_advisory_xact_lock(#{lock_key})")

      case Repo.one(
             from(s in Session,
               where: s.patient_id == ^patient_id and s.status == "open",
               limit: 1
             )
           ) do
        nil ->
          # No session exists, create one
          {:ok, session} =
            %Session{}
            |> Session.changeset(%{
              started_at: DateTime.utc_now() |> DateTime.truncate(:second),
              status: "open",
              patient_id: patient_id
            })
            |> Repo.insert()

          session

        session ->
          session
      end
    end)
  end

  @doc """
  Open a new session for a patient.
  """
  def open_session(%{id: patient_id}) when is_binary(patient_id) or is_integer(patient_id) do
    %Session{}
    |> Session.changeset(%{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "open",
      patient_id: patient_id
    })
    |> Repo.insert()
  end

  @doc """
  Close an existing session.
  """
  def close_session(session) do
    session
    |> Session.changeset(%{
      closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "closed"
    })
    |> Repo.update()
  end
end
