defmodule Alethea.Clinical.Outbox do
  @moduledoc """
  Builds content-free Oban job args for `Alethea.Clinical.Message` domain
  events — the "voz del paciente" producer for
  sdd/telegram-rag-ingestion-262 (GitHub #262, Slice 1).

  Mirrors `Alethea.ClinicalRecord.Outbox.event/2`'s SHAPE exactly (same
  `@allowed_args`, same target worker) but is intentionally NOT an
  extension of it: `Alethea.ClinicalRecord` is domain core and must not
  import `Alethea.Clinical.Message` (that would be a reverse
  cross-context dependency, forbidden by `Alethea.Clinical`'s "sin writer
  compartido" moduledoc / CLAUDE.md's hexagonal rule). `Message` also has
  no `professional_id` field, so it is threaded in as an explicit third
  argument instead of being read off the struct like
  `Alethea.ClinicalRecord.Outbox.event/2` does for its records.

  `event/3` allowlists via `Map.take/2` so extra/PII fields (in
  particular `encrypted_content`) can never leak into `oban_jobs.args`,
  even if `Message`'s shape widens later.
  """

  alias Alethea.Clinical.Message
  alias AletheaJobs.ClinicalRecordOutboxWorker

  @allowed_args ~w(event resource_type resource_id patient_id professional_id)

  @doc """
  Builds the outbox job insert changeset for `event_type` from a
  persisted `Message` and its owning patient's `professional_id`. `args`
  is restricted to identifier fields only — see `@allowed_args`.

  Guards `professional_id` as a required binary (AD5): a `nil` would
  build a job that crash-loops the worker (`Repo.get(Professional,
  nil)` raises `ArgumentError`) up to `max_attempts` times. Failing
  loudly here, at the writer, is preferable to silently enqueueing an
  unusable job.
  """
  @spec event(String.t(), Message.t(), String.t()) :: Ecto.Changeset.t()
  def event(event_type, %Message{} = message, professional_id)
      when is_binary(event_type) and is_binary(professional_id) do
    %{
      "event" => event_type,
      "resource_type" => "patient_message",
      "resource_id" => message.id,
      "patient_id" => message.patient_id,
      "professional_id" => professional_id
    }
    |> Map.take(@allowed_args)
    |> ClinicalRecordOutboxWorker.new()
  end
end
