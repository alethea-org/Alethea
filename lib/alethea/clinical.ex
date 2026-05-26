defmodule Alethea.Clinical do
  import Ecto.Query
  alias Alethea.Repo
  alias Alethea.Clinical.{Message, Summary, Trend}

  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  def list_session_messages(session_id) do
    Repo.all(
      from m in Message,
      where: m.session_id == ^session_id and m.direction == "inbound"
    )
  end

  def save_trends(patient, emotion_scores, _session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(emotion_scores, fn %{label: label, score: score} ->
      last_trend =
        Repo.one(
          from t in Trend,
          where: t.patient_id == ^patient.id and t.indicator_name == ^label,
          order_by: [desc: t.recorded_at],
          limit: 1
        )

      delta = if last_trend, do: score - last_trend.score, else: 0.0

      %Trend{}
      |> Trend.changeset(%{
        indicator_name: label,
        score: score,
        delta: delta,
        recorded_at: now,
        patient_id: patient.id
      })
      |> Repo.insert!()
    end)

    :ok
  end

  def save_summary(attrs) do
    %Summary{}
    |> Summary.changeset(attrs)
    |> Repo.insert()
  end

  def list_session_summaries(patient_id, since) do
    Repo.all(
      from s in Summary,
      where:
        s.patient_id == ^patient_id and
          s.type == "session" and
          s.period_start >= ^since
    )
  end

  def aggregate_trends(patient_id, since) do
    Repo.all(
      from t in Trend,
      where: t.patient_id == ^patient_id and t.recorded_at >= ^since,
      group_by: t.indicator_name,
      select: {t.indicator_name, avg(t.score)}
    )
    |> Enum.map(fn {name, avg_score} -> %{label: name, score: avg_score} end)
  end

  def decrypt_content(encrypted_content) do
    Alethea.Encryption.Vault.decrypt!(encrypted_content)
  end
end
