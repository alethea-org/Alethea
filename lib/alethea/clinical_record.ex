defmodule Alethea.ClinicalRecord do
  @moduledoc """
  Professional-authored clinical record: target behaviors and immutable
  clinical notes (sdd/clinical-record-foundation, GitHub #194).

  **Boundary note**: this context is distinct from `Alethea.Clinical`,
  which owns patient Telegram journaling (messages, summaries, trends).
  The two are structurally separate — different tables, no shared
  writer, no AI write path into `target_behaviors` or `clinical_notes`.
  Any file that imports both MUST alias one explicitly, e.g.
  `alias Alethea.Clinical, as: Journaling`, to avoid visual collision.

  `create_target_behavior/3` (PR2) and `create_clinical_note/3` (PR3)
  are the public seam — see `Alethea.ClinicalRecord.TargetBehavior`,
  `Alethea.ClinicalRecord.ClinicalNote`, `Alethea.ClinicalRecord.Audit`,
  and `Alethea.ClinicalRecord.Outbox` for the building blocks shipped
  in PR1.
  """

  require Logger

  alias Alethea.Accounts
  alias Alethea.Accounts.{Patient, Professional}

  alias Alethea.ClinicalRecord.{
    AIProposal,
    Audit,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    DismissedEvidenceSuggestion,
    EvidenceSource,
    FunctionalAnalysisContent,
    FunctionalAnalysisDraft,
    FunctionalAnalysisVersion,
    Outbox,
    SessionTranscript,
    SessionTranscriptContent,
    TargetBehavior
  }

  alias Alethea.ClinicalRecord.Rag.Retrieval
  alias Alethea.ClinicalRecord.SourceRef
  alias Alethea.ClinicalRecord.Tombstone
  alias Alethea.Encryption.PatientVault
  alias Alethea.Repo

  import Ecto.Query

  @typedoc """
  Both DEKs a `with_patient/3`-routed function may need to encrypt/decrypt
  a `ClinicalRecord` row, keyed by that row's own `encryption_version` (D1,
  sdd/clinical-record-retention, GitHub #197): `1` decrypts under the
  shared `Alethea.Clinical` patient DEK, `2` under the CR-scoped
  `"patient_clinical_record"` DEK. `create_target_behavior/3` and
  `create_clinical_note/3` bypass this seam entirely (see their own
  moduledocs) and always stay on the shared patient DEK.
  """
  @type keyring :: %{patient_dek: binary(), clinical_record_dek: binary()}

  @doc """
  Authorizes via `Accounts.get_patient_for_professional/2`, encrypts
  `description` under the patient's DEK, and commits the target
  behavior row, a content-free audit row, and an outbox job in one
  `Ecto.Multi` — all-or-nothing.
  """
  @spec create_target_behavior(Professional.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, TargetBehavior.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :empty_plaintext
             | :invalid_key_size
             | :encryption_failed
             | Ecto.Changeset.t()
             | term()}
  def create_target_behavior(%Professional{} = professional, patient_id, description) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek),
             {:ok, ciphertext} <- PatientVault.encrypt(description, dek) do
          insert_target_behavior(professional, patient, ciphertext)
        end
    end
  end

  @doc """
  Authorizes via `Accounts.get_patient_for_professional/2`, encrypts
  `body` under the patient's DEK, and commits the clinical note row, a
  content-free audit row, and an outbox job in one `Ecto.Multi` —
  all-or-nothing. The resulting `ClinicalNote` row is immutable
  (no update changeset, no `updated_at`, DB-level `BEFORE UPDATE`
  trigger — see `Alethea.ClinicalRecord.ClinicalNote`).
  """
  @spec create_clinical_note(Professional.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ClinicalNote.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :empty_plaintext
             | :invalid_key_size
             | :encryption_failed
             | Ecto.Changeset.t()
             | term()}
  def create_clinical_note(%Professional{} = professional, patient_id, body) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek),
             {:ok, ciphertext} <- PatientVault.encrypt(body, dek) do
          insert_clinical_note(professional, patient, ciphertext)
        end
    end
  end

  @doc """
  Lists all clinical notes for an authorized patient in reverse-chronological order,
  decrypting each note's encrypted body under the patient's DEK. Preloads the professional
  author.

  Returns `{:ok, [ClinicalNote.t()]}` on success, or `{:error, :unauthorized}`
  if the professional is not authorized for this patient.
  """
  @spec list_clinical_notes(Professional.t(), Ecto.UUID.t()) ::
          {:ok, [ClinicalNote.t()]} | {:error, :unauthorized | term()}
  def list_clinical_notes(%Professional{} = professional, patient_id) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek) do
          notes =
            ClinicalNote
            |> where([n], n.patient_id == ^patient.id)
            |> order_by([n], desc: n.inserted_at, desc: n.id)
            |> preload([:professional])
            |> Repo.all()
            |> Enum.map(fn note ->
              %{note | body: decrypt_or_placeholder(note.encrypted_body, dek)}
            end)

          {:ok, notes}
        end
    end
  end

  @doc """
  Lists target behaviors for an authorized patient in reverse-chronological
  order. Each result contains only the target behavior id, its decrypted
  description, and a content-free functional-analysis status derived from the
  current draft or its legal-deletion tombstone.
  """
  @spec list_target_behaviors(Professional.t(), Ecto.UUID.t()) ::
          {:ok,
           [
             %{
               id: Ecto.UUID.t(),
               description: String.t(),
               functional_analysis_status: :not_started | :saved | :legally_deleted
             }
           ]}
          | {:error, :unauthorized | term()}
  def list_target_behaviors(%Professional{} = professional, patient_id) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, dek} <- Accounts.load_patient_dek(patient, kek) do
          target_behaviors =
            TargetBehavior
            |> where([target], target.patient_id == ^patient.id)
            |> order_by([target], desc: target.inserted_at, desc: target.id)
            |> Repo.all()

          {saved_ids, deleted_ids} =
            functional_analysis_status_ids(patient.id, Enum.map(target_behaviors, & &1.id))

          behaviors =
            Enum.map(target_behaviors, fn target_behavior ->
              %{
                id: target_behavior.id,
                description: decrypt_or_placeholder(target_behavior.encrypted_description, dek),
                functional_analysis_status:
                  functional_analysis_status(target_behavior.id, saved_ids, deleted_ids)
              }
            end)

          {:ok, behaviors}
        end
    end
  end

  defp functional_analysis_status_ids(_patient_id, []), do: {MapSet.new(), MapSet.new()}

  defp functional_analysis_status_ids(patient_id, target_behavior_ids) do
    saved_ids =
      FunctionalAnalysisDraft
      |> where([draft], draft.patient_id == ^patient_id)
      |> where([draft], draft.target_behavior_id in ^target_behavior_ids)
      |> select([draft], draft.target_behavior_id)
      |> Repo.all()
      |> MapSet.new()

    deleted_ids =
      Tombstone
      |> where(
        [tombstone],
        tombstone.patient_id == ^patient_id and
          tombstone.resource_type == "functional_analysis_draft" and
          tombstone.target_behavior_id in ^target_behavior_ids
      )
      |> select([tombstone], tombstone.target_behavior_id)
      |> Repo.all()
      |> MapSet.new()

    {saved_ids, deleted_ids}
  end

  defp functional_analysis_status(target_behavior_id, saved_ids, deleted_ids) do
    cond do
      MapSet.member?(saved_ids, target_behavior_id) -> :saved
      MapSet.member?(deleted_ids, target_behavior_id) -> :legally_deleted
      true -> :not_started
    end
  end

  # Authorizes via `Accounts.get_patient_for_professional/2`, then loads the
  # professional's KEK and BOTH DEKs (the shared patient DEK and the
  # CR-scoped "patient_clinical_record" DEK, lazily provisioned here — D1,
  # sdd/clinical-record-retention, GitHub #197), and invokes
  # `fun.(patient, keyring)` (was `fun.(patient, dek)` pre-#197 —
  # sdd/alethea/issue-195-clinical-review-workbench, PR2a). Extracted
  # because the auth→KEK→DEK ladder repeats across all the write functions
  # below — see design's Technical Approach. `create_target_behavior/3` and
  # `create_clinical_note/3` above are intentionally left untouched (design:
  # refactor only if the diff stays inside the slice budget) — they never
  # call this seam and always stay on the shared patient DEK.
  #
  # On a missing/unauthorized patient, logs a denial audit row (no DEK/KEK
  # load happens) and returns `{:error, :unauthorized}` without calling `fun`.
  @spec with_patient(Professional.t(), Ecto.UUID.t(), (Patient.t(), keyring() -> result)) ::
          result | {:error, :unauthorized}
        when result: {:ok, term()} | {:error, term()}
  defp with_patient(%Professional{} = professional, patient_id, fun) when is_function(fun, 2) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, kek} <- Accounts.load_professional_kek(professional),
             {:ok, patient_dek} <- Accounts.load_patient_dek(patient, kek),
             {:ok, clinical_record_dek} <- Accounts.ensure_clinical_record_dek(patient, kek) do
          fun.(patient, %{patient_dek: patient_dek, clinical_record_dek: clinical_record_dek})
        end
    end
  end

  @doc """
  Loads a target behavior authorized by `(professional, patient_id,
  target_behavior_id)` (GitHub #289). The row is fetched scoped by the
  authorized patient's id, so a target behavior belonging to another
  patient — or a malformed id — yields `{:error, :not_found}` and never
  reveals whether that id exists elsewhere. A cross-patient attempt writes
  a content-free denial audit row. When DEK is available, decrypts
  `encrypted_description` into the virtual `:description` field and
  attaches `:patient` for clinical workbench views.
  """
  @spec get_target_behavior(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, TargetBehavior.t()} | {:error, :unauthorized | :not_found}
  def get_target_behavior(%Professional{} = professional, patient_id, target_behavior_id) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        with {:ok, target_behavior} <-
               fetch_owned_target_behavior(professional, patient, target_behavior_id) do
          decrypted = decrypt_target_behavior(professional, patient, target_behavior)
          {:ok, decrypted}
        end
    end
  end

  # `with_patient/3` plus the patient↔target-behavior ownership check
  # (GitHub #289). Every function that reads or writes by `target_behavior_id`
  # goes through here, so `fun` only runs for a target behavior that belongs
  # to the authorized patient — otherwise nothing is read or written.
  @spec with_target_behavior(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          (Patient.t(), keyring() -> result)
        ) :: result | {:error, :unauthorized | :not_found}
        when result: {:ok, term()} | {:error, term()}
  defp with_target_behavior(professional, patient_id, target_behavior_id, fun)
       when is_function(fun, 2) do
    with_patient(professional, patient_id, fn patient, keyring ->
      with {:ok, _target_behavior} <-
             fetch_owned_target_behavior(professional, patient, target_behavior_id) do
        fun.(patient, keyring)
      end
    end)
  end

  defp fetch_owned_target_behavior(professional, patient, target_behavior_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(target_behavior_id),
         %TargetBehavior{} = target_behavior <-
           Repo.get_by(TargetBehavior, id: uuid, patient_id: patient.id) do
      {:ok, target_behavior}
    else
      _ ->
        # A malformed id cannot be stored in the `binary_id` audit column and
        # must not be echoed into the audit trail — record the denial without it.
        audited_id =
          case Ecto.UUID.cast(target_behavior_id) do
            {:ok, uuid} -> uuid
            :error -> nil
          end

        log_denied_audit(professional.id, audited_id, "target_behavior")
        {:error, :not_found}
    end
  end

  # Locks the TargetBehavior row FOR UPDATE inside an already-open transaction
  # and revalidates that it exists and belongs to the patient. If it was deleted
  # between authorization and lock acquisition, returns {:error, {:denied_target, audited_id}}.
  defp lock_and_validate_target_behavior(_professional, patient, target_behavior_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(target_behavior_id) do
      query =
        from t in TargetBehavior,
          where: t.id == ^uuid and t.patient_id == ^patient.id,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        %TargetBehavior{} = tb ->
          {:ok, tb}

        nil ->
          {:error, {:denied_target, uuid}}
      end
    else
      _ ->
        {:error, {:denied_target, nil}}
    end
  end

  defp decrypt_target_behavior(professional, patient, target_behavior) do
    with {:ok, kek} <- Accounts.load_professional_kek(professional),
         {:ok, dek} <- Accounts.load_patient_dek(patient, kek),
         {:ok, plaintext} <- PatientVault.decrypt(target_behavior.encrypted_description, dek) do
      %{target_behavior | description: plaintext, patient: patient}
    else
      _ ->
        %{target_behavior | description: "[No disponible]", patient: patient}
    end
  end

  # Picks the correct DEK out of `keyring` for a row per its OWN stored
  # `encryption_version` (AD1, sdd/clinical-record-retention, GitHub #197)
  # — never a caller-wide assumption. Pre-change rows stay `1` forever
  # (no backfill); every new write through `with_patient/3` stamps `2`.
  @spec dek_for(%{encryption_version: 1 | 2}, keyring()) :: binary()
  defp dek_for(%{encryption_version: 1}, keyring), do: keyring.patient_dek
  defp dek_for(%{encryption_version: 2}, keyring), do: keyring.clinical_record_dek

  @doc """
  Authorizes via `with_patient/3`, validates and serializes the spans, encrypts
  them under the patient's clinical-record DEK, and commits the transcript row,
  a content-free audit row, and one identifier-only outbox job in a single
  `Ecto.Multi` — all-or-nothing (sdd/session-transcript-317, GitHub #317).

  An invalid speaker (or malformed span) rejects the WHOLE transcript before the
  transaction opens: no row, no audit-success row, no outbox job.
  """
  @spec create_session_transcript(Professional.t(), Ecto.UUID.t(), %{
          required(:spans) => [map()],
          required(:recorded_at) => DateTime.t(),
          optional(:audio_duration_seconds) => non_neg_integer() | nil
        }) ::
          {:ok, SessionTranscript.t()}
          | {:error,
             :unauthorized
             | SessionTranscriptContent.error()
             | :empty_plaintext
             | :invalid_key_size
             | :encryption_failed
             | Ecto.Changeset.t()
             | term()}
  def create_session_transcript(%Professional{} = professional, patient_id, attrs)
      when is_map(attrs) do
    with_patient(professional, patient_id, fn patient, keyring ->
      with {:ok, content} <- SessionTranscriptContent.new(Map.fetch!(attrs, :spans)) do
        persist_session_transcript(professional, patient, content, attrs, keyring)
      end
    end)
  end

  @doc """
  Loads one transcript authorized by `(professional, patient_id, transcript_id)`,
  with `:spans` decrypted and parsed. The row is fetched scoped by the
  authorized patient's id, so a transcript belonging to another patient — or a
  malformed id — yields `{:error, :not_found}` and never reveals whether that
  id exists elsewhere. A cross-patient attempt writes a content-free denial
  audit row (sdd/session-transcript-317, GitHub #317).
  """
  @spec get_session_transcript(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SessionTranscript.t()}
          | {:error, :unauthorized | :not_found | :undecryptable | term()}
  def get_session_transcript(%Professional{} = professional, patient_id, transcript_id) do
    with_patient(professional, patient_id, fn patient, keyring ->
      with {:ok, transcript} <-
             fetch_owned_session_transcript(professional, patient, transcript_id),
           {:ok, plaintext} <-
             PatientVault.decrypt(transcript.encrypted_spans, dek_for(transcript, keyring)),
           {:ok, content} <- SessionTranscriptContent.parse(plaintext) do
        {:ok, %{transcript | spans: content.spans}}
      else
        {:error, :not_found} -> {:error, :not_found}
        {:error, _reason} -> {:error, :undecryptable}
      end
    end)
  end

  # `with_patient/3` plus the patient↔transcript ownership check, mirroring
  # `fetch_owned_target_behavior/3` exactly — including the malformed-UUID
  # normalization to `nil` before auditing (#317).
  defp fetch_owned_session_transcript(professional, patient, transcript_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(transcript_id),
         %SessionTranscript{} = transcript <-
           Repo.get_by(SessionTranscript, id: uuid, patient_id: patient.id) do
      {:ok, transcript}
    else
      _ ->
        audited_id =
          case Ecto.UUID.cast(transcript_id) do
            {:ok, uuid} -> uuid
            :error -> nil
          end

        log_denied_audit(professional.id, audited_id, "session_transcript")
        {:error, :not_found}
    end
  end

  defp persist_session_transcript(professional, patient, content, attrs, keyring) do
    body = SessionTranscriptContent.serialize(content)

    with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
      changeset =
        SessionTranscript.changeset(%SessionTranscript{}, %{
          encrypted_spans: ciphertext,
          encryption_version: 2,
          audio_duration_seconds: Map.get(attrs, :audio_duration_seconds),
          recorded_at: Map.fetch!(attrs, :recorded_at),
          patient_id: patient.id,
          professional_id: professional.id
        })

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:record, changeset)
      |> Ecto.Multi.insert(:audit, fn %{record: record} ->
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "session_transcript_created",
          resource_type: "session_transcript",
          resource_id: record.id,
          outcome: "success"
        })
      end)
      |> Oban.insert(:outbox_event, fn %{record: record} ->
        Outbox.event("session_transcript_created", record)
      end)
      |> Repo.transaction()
      |> finalize_record_multi()
    end
  end

  @doc """
  Lists the complete, decrypted clinical notes and journaling messages that an
  authorized professional may cite for a patient. The read-only
  `EvidenceSource` adapter owns all cross-context source reads and prioritizes
  inbound messages while retaining direction and provenance metadata.
  """
  @spec list_evidence_sources(Professional.t(), Ecto.UUID.t()) ::
          {:ok, [EvidenceSource.t()]} | {:error, :unauthorized | term()}
  def list_evidence_sources(%Professional{} = professional, patient_id) do
    with_patient(professional, patient_id, fn patient, keyring ->
      EvidenceSource.list(patient.id, keyring)
    end)
  end

  @doc """
  Suggests patient-scoped RAG evidence for an authorized target behavior.

  The explicit `:query` or `:description` option overrides the target
  behavior description. Blank descriptions produce no suggestions and do not
  invoke the embeddings adapter.
  """
  @spec suggest_evidence_candidates(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, [Retrieval.result()]}
          | {:error, :unauthorized | :not_found | term()}
  def suggest_evidence_candidates(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        opts \\ []
      ) do
    with {:ok, target_behavior} <-
           get_target_behavior(professional, patient_id, target_behavior_id) do
      description = opts[:query] || opts[:description] || target_behavior.description

      if blank_description?(description) do
        {:ok, []}
      else
        case Retrieval.suggest(
               professional,
               patient_id,
               description,
               Keyword.put(opts, :target_behavior_id, target_behavior_id)
             ) do
          {:ok, %{results: results}} -> {:ok, results}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp blank_description?(description) do
    case List.wrap(description) do
      [] -> true
      [value] -> String.trim(value) == ""
    end
  end

  @doc """
  Searches patient-scoped RAG evidence for an authorized target behavior using a
  natural-language query.

  Delegates to `suggest_evidence_candidates/4` with `query: query`, preserving
  candidate ranking, affinity scoring, and dismissal filters.
  """
  @spec search_evidence_candidates(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, [Retrieval.result()]}
          | {:error, :unauthorized | :not_found | term()}
  def search_evidence_candidates(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        query,
        opts \\ []
      ) do
    suggest_evidence_candidates(
      professional,
      patient_id,
      target_behavior_id,
      Keyword.put(opts, :query, query)
    )
  end

  @doc """
  Records a dismissed evidence suggestion for an authorized target behavior.

  Passing a UUID string is shorthand for `%{chunk_id: uuid}`. Repeating a
  dismissal for an existing chunk or resource returns the existing row without
  writing a duplicate audit entry.
  """
  @spec dismiss_evidence_suggestion(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t() | map()
        ) ::
          {:ok, DismissedEvidenceSuggestion.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def dismiss_evidence_suggestion(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        attrs_or_chunk_id
      ) do
    attrs = normalize_dismissal_attrs(attrs_or_chunk_id)

    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, _keyring ->
      case find_existing_dismissal(target_behavior_id, attrs) do
        %DismissedEvidenceSuggestion{} = dismissal ->
          {:ok, dismissal}

        nil ->
          persist_dismissed_evidence_suggestion(
            professional,
            patient,
            target_behavior_id,
            attrs
          )
      end
    end)
  end

  @doc """
  Lists the distinct, non-nil chunk and resource identifiers dismissed for an
  authorized target behavior.
  """
  @spec list_dismissed_suggestion_ids(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :unauthorized | :not_found | term()}
  def list_dismissed_suggestion_ids(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn _patient, _keyring ->
      ids =
        DismissedEvidenceSuggestion
        |> where([dismissal], dismissal.target_behavior_id == ^target_behavior_id)
        |> select([dismissal], {dismissal.chunk_id, dismissal.resource_id})
        |> Repo.all()
        |> Enum.flat_map(fn {chunk_id, resource_id} -> [chunk_id, resource_id] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, ids}
    end)
  end

  @doc """
  Lists dismissed evidence suggestions for an authorized target behavior in
  reverse dismissal order.
  """
  @spec list_dismissed_evidence_suggestions(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) ::
          {:ok, [DismissedEvidenceSuggestion.t()]}
          | {:error, :unauthorized | :not_found | term()}
  def list_dismissed_evidence_suggestions(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn _patient, _keyring ->
      dismissals =
        DismissedEvidenceSuggestion
        |> where([dismissal], dismissal.target_behavior_id == ^target_behavior_id)
        |> order_by([dismissal], desc: dismissal.dismissed_at, desc: dismissal.id)
        |> Repo.all()

      {:ok, dismissals}
    end)
  end

  defp normalize_dismissal_attrs(chunk_id) when is_binary(chunk_id) do
    %{chunk_id: chunk_id, resource_id: nil, resource_type: nil, dismissed_at: nil}
  end

  defp normalize_dismissal_attrs(attrs) when is_map(attrs) do
    %{
      chunk_id: Map.get(attrs, :chunk_id) || Map.get(attrs, "chunk_id"),
      resource_id: Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id"),
      resource_type: Map.get(attrs, :resource_type) || Map.get(attrs, "resource_type"),
      dismissed_at: Map.get(attrs, :dismissed_at) || Map.get(attrs, "dismissed_at")
    }
  end

  defp find_existing_dismissal(target_behavior_id, attrs) do
    chunk_id = attrs.chunk_id
    resource_id = attrs.resource_id

    case {chunk_id, resource_id} do
      {nil, nil} ->
        nil

      {chunk_id, nil} ->
        Repo.get_by(DismissedEvidenceSuggestion,
          target_behavior_id: target_behavior_id,
          chunk_id: chunk_id
        )

      {nil, resource_id} ->
        Repo.get_by(DismissedEvidenceSuggestion,
          target_behavior_id: target_behavior_id,
          resource_id: resource_id
        )

      {chunk_id, resource_id} ->
        DismissedEvidenceSuggestion
        |> where(
          [dismissal],
          dismissal.target_behavior_id == ^target_behavior_id and
            (dismissal.chunk_id == ^chunk_id or dismissal.resource_id == ^resource_id)
        )
        |> order_by([dismissal], desc: dismissal.dismissed_at, desc: dismissal.id)
        |> Repo.one()
    end
  end

  defp persist_dismissed_evidence_suggestion(
         professional,
         patient,
         target_behavior_id,
         attrs
       ) do
    changeset =
      DismissedEvidenceSuggestion.changeset(
        %DismissedEvidenceSuggestion{},
        Map.merge(attrs, %{
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior_id
        })
      )

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:record, changeset)
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: "evidence_suggestion_dismissed",
        resource_type: "dismissed_evidence_suggestion",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, :record, reason, _changes} ->
        case find_existing_dismissal(target_behavior_id, attrs) do
          %DismissedEvidenceSuggestion{} = dismissal -> {:ok, dismissal}
          nil -> {:error, reason}
        end

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record dismissal multi failed at #{step}")
        {:error, reason}
    end
  end

  @doc """
  Creates immutable consultation evidence from a trusted patient-owned source.

  The client supplies only source identity and an excerpt candidate. This
  function re-fetches and decrypts the authoritative source under the
  authorized patient, requires the candidate to occur exactly in its plaintext,
  and derives `occurred_at` from the source before using the existing encrypted
  evidence, audit, and outbox transaction.
  """
  @spec cite_evidence_source(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t(), %{
          required(:source_kind) => String.t(),
          required(:source_id) => Ecto.UUID.t(),
          required(:excerpt) => String.t(),
          optional(:span_hint) => map()
        }) ::
          {:ok, ConsultationEvidence.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :unsupported_source
             | :excerpt_not_found
             | Ecto.Changeset.t()
             | term()}
  def cite_evidence_source(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        %{source_kind: source_kind, source_id: source_id, excerpt: excerpt} = attrs
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      with {:ok, source} <-
             EvidenceSource.fetch(source_kind, source_id, patient.id, keyring),
           {:ok, markers} <- locate_excerpt(source, excerpt, Map.get(attrs, :span_hint)) do
        insert_consultation_evidence(
          professional,
          patient,
          target_behavior_id,
          keyring,
          Atom.to_string(source.kind),
          source.id,
          excerpt,
          source.occurred_at,
          markers
        )
      end
    end)
  end

  @doc """
  Cites a source-derived fact (a `clinical_note` or a `message`) onto the
  review timeline. Copies and encrypts the exact `excerpt` under the
  patient's DEK at citation time (design A3) — `attrs` carries `source_kind`,
  `source_id` (untyped, no FK — design A2), `excerpt`, and `occurred_at`.

  This compatibility API trusts its caller. New UI paths must use
  `cite_evidence_source/4`, which validates source ownership and plaintext.
  """
  @deprecated "Compatibility only; use cite_evidence_source/4 to validate source ownership and plaintext"
  @spec add_consultation_evidence(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t(), %{
          required(:source_kind) => String.t(),
          required(:source_id) => Ecto.UUID.t(),
          required(:excerpt) => String.t(),
          required(:occurred_at) => DateTime.t()
        }) ::
          {:ok, ConsultationEvidence.t()}
          | {:error, :unauthorized | Ecto.Changeset.t() | term()}
  def add_consultation_evidence(%Professional{} = professional, patient_id, target_behavior_id, %{
        source_kind: source_kind,
        source_id: source_id,
        excerpt: excerpt,
        occurred_at: occurred_at
      }) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      insert_consultation_evidence(
        professional,
        patient,
        target_behavior_id,
        keyring,
        source_kind,
        source_id,
        excerpt,
        occurred_at,
        %{}
      )
    end)
  end

  defp exact_excerpt(plaintext, excerpt)
       when is_binary(excerpt) and byte_size(excerpt) > 0 do
    if String.contains?(plaintext, excerpt), do: :ok, else: {:error, :excerpt_not_found}
  end

  defp exact_excerpt(_plaintext, _excerpt), do: {:error, :excerpt_not_found}

  # AD2: for a `session_transcript` source, markers come from the
  # AUTHORITATIVE decrypted span, never from the caller-supplied `hint` —
  # the hint (built server-side from `socket.assigns`, never from client
  # params) only selects WHICH span among those containing `excerpt`. Every
  # other source kind keeps the existing whole-content excerpt check and
  # returns no markers.
  defp locate_excerpt(%EvidenceSource{kind: :session_transcript, spans: spans}, excerpt, hint) do
    matches = Enum.filter(spans, &(exact_excerpt(&1.text, excerpt) == :ok))

    matches
    |> find_hinted_span(hint)
    |> case do
      nil ->
        {:error, :excerpt_not_found}

      span ->
        {:ok,
         %{
           speaker: span.speaker,
           audio_start_seconds: span.start * 1.0,
           audio_end_seconds: span.end * 1.0
         }}
    end
  end

  defp locate_excerpt(%EvidenceSource{content: content}, excerpt, _hint) do
    case exact_excerpt(content, excerpt) do
      :ok -> {:ok, %{}}
      error -> error
    end
  end

  defp find_hinted_span(matches, nil), do: List.first(matches)

  defp find_hinted_span(matches, hint) do
    Enum.find(matches, fn span ->
      span.speaker == Map.get(hint, :speaker) and
        span.start * 1.0 == Map.get(hint, :audio_start_seconds) and
        span.end * 1.0 == Map.get(hint, :audio_end_seconds)
    end)
  end

  defp insert_consultation_evidence(
         professional,
         patient,
         target_behavior_id,
         keyring,
         source_kind,
         source_id,
         excerpt,
         occurred_at,
         markers
       ) do
    with {:ok, ciphertext} <- PatientVault.encrypt(excerpt, keyring.clinical_record_dek) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :record,
        ConsultationEvidence.changeset(
          %ConsultationEvidence{},
          Map.merge(
            %{
              source_kind: source_kind,
              source_id: source_id,
              encrypted_excerpt: ciphertext,
              encryption_version: 2,
              occurred_at: occurred_at,
              patient_id: patient.id,
              professional_id: professional.id,
              target_behavior_id: target_behavior_id
            },
            markers
          )
        )
      )
      |> Ecto.Multi.insert(:audit, fn %{record: record} ->
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "consultation_evidence_created",
          resource_type: "consultation_evidence",
          resource_id: record.id,
          outcome: "success"
        })
      end)
      |> Oban.insert(:outbox_event, fn %{record: record} ->
        Outbox.event("consultation_evidence_created", record)
      end)
      |> Repo.transaction()
      |> finalize_record_multi()
    end
  end

  @doc """
  Adds a clinician-authored free-text observation directly to the review
  timeline. Unlike `add_consultation_evidence/4`, no source is cited — the
  absence of source columns on `ClinicianObservation` is itself the
  "uncited" marker (design A1). `occurred_at` is set to the current time:
  unlike cited evidence, a clinician observation has no independent
  historical timestamp to preserve.
  """
  @spec add_clinician_observation(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ClinicianObservation.t()}
          | {:error, :unauthorized | Ecto.Changeset.t() | term()}
  def add_clinician_observation(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        body
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :record,
          ClinicianObservation.changeset(%ClinicianObservation{}, %{
            encrypted_body: ciphertext,
            encryption_version: 2,
            occurred_at: DateTime.utc_now(),
            patient_id: patient.id,
            professional_id: professional.id,
            target_behavior_id: target_behavior_id
          })
        )
        |> Ecto.Multi.insert(:audit, fn %{record: record} ->
          Audit.changeset(%Audit{
            professional_id: professional.id,
            action: "clinician_observation_created",
            resource_type: "clinician_observation",
            resource_id: record.id,
            outcome: "success"
          })
        end)
        |> Oban.insert(:outbox_event, fn %{record: record} ->
          Outbox.event("clinician_observation_created", record)
        end)
        |> Repo.transaction()
        |> finalize_record_multi()
      end
    end)
  end

  @doc """
  Edits an existing clinician observation's body in place. The row is
  re-loaded scoped by `patient_id` (from the authorized patient) so an
  observation id belonging to a different patient cannot be mutated by id
  guessing — returns `{:error, :not_found}` in that case.
  """
  @spec update_clinician_observation(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, ClinicianObservation.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def update_clinician_observation(
        %Professional{} = professional,
        patient_id,
        observation_id,
        body
      ) do
    with_patient(professional, patient_id, fn patient, keyring ->
      case Repo.get_by(ClinicianObservation, id: observation_id, patient_id: patient.id) do
        nil ->
          tombstone_gate(professional.id, observation_id, "clinician_observation")

        observation ->
          with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
            Ecto.Multi.new()
            |> Ecto.Multi.update(
              :record,
              ClinicianObservation.update_changeset(observation, %{
                encrypted_body: ciphertext,
                encryption_version: 2
              })
            )
            |> Ecto.Multi.insert(:audit, fn %{record: record} ->
              Audit.changeset(%Audit{
                professional_id: professional.id,
                action: "clinician_observation_updated",
                resource_type: "clinician_observation",
                resource_id: record.id,
                outcome: "success"
              })
            end)
            |> Oban.insert(:outbox_event, fn %{record: record} ->
              Outbox.event("clinician_observation_updated", record)
            end)
            |> Repo.transaction()
            |> finalize_record_multi()
          end
      end
    end)
  end

  @doc """
  Dispatches AI functional-analysis pattern generation for a target
  behavior — the only clinician-triggered entry point into the AI path
  (design D2: no automatic generation on evidence change). Inserts **no**
  domain record itself; the resulting `AIProposal` rows are inserted only
  by `AletheaJobs.AIProposalWorker` (PR4), always `status: "pending"`
  (design A6). Enqueues the job by worker name (string) rather than the
  module directly: `AIProposalWorker` is out of this PR's scope and does
  not exist yet — Oban resolves the worker module only when the job is
  later executed, not at insert time.
  """
  @spec request_ai_proposals(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :requested} | {:error, :unauthorized | :not_found | term()}
  def request_ai_proposals(%Professional{} = professional, patient_id, target_behavior_id) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, _keyring ->
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :audit,
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "ai_proposals_requested",
          resource_type: "target_behavior",
          resource_id: target_behavior_id,
          outcome: "success"
        })
      )
      |> Oban.insert(:ai_proposal_job, fn _changes ->
        Oban.Job.new(
          %{
            "professional_id" => professional.id,
            "patient_id" => patient.id,
            "target_behavior_id" => target_behavior_id
          },
          worker: "AletheaJobs.AIProposalWorker",
          queue: :ai_analysis,
          max_attempts: 1,
          unique: [period: 60, fields: [:args]]
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{ai_proposal_job: _job}} ->
          {:ok, :requested}

        {:error, step, reason, _changes} ->
          Logger.warning("clinical_record multi failed at #{step}")
          {:error, reason}
      end
    end)
  end

  @doc """
  Accepts a pending/edited AI proposal (design D5: soft status transition,
  row kept). Re-loads the row scoped by `patient_id` — see
  `update_clinician_observation/4` moduledoc for the id-guessing rationale.
  """
  @spec accept_ai_proposal(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, AIProposal.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def accept_ai_proposal(%Professional{} = professional, patient_id, proposal_id) do
    with_patient(professional, patient_id, fn patient, _keyring ->
      update_ai_proposal_status(
        professional,
        patient,
        proposal_id,
        %{status: "accepted"},
        "ai_proposal_accepted"
      )
    end)
  end

  @doc """
  Atomically accepts an AI proposal and merges its text into the
  functional-analysis draft — all-or-nothing (#291). If the draft update
  fails, the proposal stays in its previous status (no partial accept).

  The proposal text is appended to the existing draft body (or to an
  empty string if no draft exists yet). Both the proposal status update,
  the draft upsert, audit rows, and outbox events are committed in a
  single `Ecto.Multi` transaction.
  """
  @spec accept_ai_proposal_into_draft(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) ::
          {:ok, %{proposal: AIProposal.t(), draft: FunctionalAnalysisDraft.t()}}
          | {:error, :unauthorized | :not_found | :legally_deleted | Ecto.Changeset.t() | term()}
  def accept_ai_proposal_into_draft(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        proposal_id
      ) do
    with_patient(professional, patient_id, fn patient, keyring ->
      dek = keyring.clinical_record_dek

      Repo.transaction(fn ->
        case lock_and_validate_target_behavior(professional, patient, target_behavior_id) do
          {:ok, _target_behavior} ->
            case Tombstone.for_target_behavior(target_behavior_id, "functional_analysis_draft") do
              %Tombstone{resource_id: resource_id} ->
                {:denied_tombstone, resource_id}

              nil ->
                case Repo.get_by(AIProposal,
                       id: proposal_id,
                       patient_id: patient.id,
                       target_behavior_id: target_behavior_id
                     ) do
                  nil ->
                    {:not_found_proposal, proposal_id}

                  %AIProposal{} = proposal ->
                    case PatientVault.decrypt(proposal.encrypted_text, dek_for(proposal, keyring)) do
                      {:ok, proposal_text} ->
                        current_body =
                          load_current_draft_body(patient.id, target_behavior_id, keyring)

                        new_body = merge_draft_body(current_body, proposal_text)

                        with {:ok, ciphertext} <- PatientVault.encrypt(new_body, dek) do
                          existing_draft =
                            Repo.get_by(FunctionalAnalysisDraft,
                              target_behavior_id: target_behavior_id,
                              patient_id: patient.id
                            )

                          next_lock_version =
                            if existing_draft, do: (existing_draft.lock_version || 0) + 1, else: 1

                          draft_changeset =
                            FunctionalAnalysisDraft.changeset(%FunctionalAnalysisDraft{}, %{
                              encrypted_body: ciphertext,
                              encryption_version: 2,
                              lock_version: next_lock_version,
                              patient_id: patient.id,
                              professional_id: professional.id,
                              target_behavior_id: target_behavior_id
                            })

                          action = "ai_proposal_accepted_into_draft"

                          multi_result =
                            Ecto.Multi.new()
                            |> Ecto.Multi.update(
                              :proposal,
                              AIProposal.update_changeset(proposal, %{status: "accepted"})
                            )
                            |> Ecto.Multi.insert(:draft, draft_changeset,
                              on_conflict:
                                {:replace,
                                 [
                                   :encrypted_body,
                                   :encryption_version,
                                   :lock_version,
                                   :professional_id,
                                   :updated_at
                                 ]},
                              conflict_target: :target_behavior_id,
                              returning: true
                            )
                            |> Ecto.Multi.insert(:audit_proposal, fn %{proposal: record} ->
                              Audit.changeset(%Audit{
                                professional_id: professional.id,
                                action: action,
                                resource_type: "ai_proposal",
                                resource_id: record.id,
                                outcome: "success"
                              })
                            end)
                            |> Ecto.Multi.insert(:audit_draft, fn %{draft: record} ->
                              Audit.changeset(%Audit{
                                professional_id: professional.id,
                                action: action,
                                resource_type: "functional_analysis_draft",
                                resource_id: record.id,
                                outcome: "success"
                              })
                            end)
                            |> Oban.insert(:outbox_proposal, fn %{proposal: record} ->
                              Outbox.event(action, record)
                            end)
                            |> Oban.insert(:outbox_draft, fn %{draft: record} ->
                              Outbox.event(action, record)
                            end)
                            |> Repo.transaction()

                          case multi_result do
                            {:ok, %{proposal: p, draft: d}} ->
                              %{proposal: p, draft: d}

                            {:error, step, reason, _changes} ->
                              Logger.warning("clinical_record multi failed at #{step}")
                              Repo.rollback(reason)
                          end
                        else
                          {:error, reason} -> Repo.rollback(reason)
                        end

                      {:error, reason} ->
                        Repo.rollback(reason)
                    end
                end
            end

          {:error, {:denied_target, audited_id}} ->
            {:denied_target, audited_id}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:denied_tombstone, resource_id}} ->
          log_denied_audit(professional.id, resource_id, "functional_analysis_draft")
          {:error, :legally_deleted}

        {:ok, {:not_found_proposal, prop_id}} ->
          deny_or_not_found(professional.id, prop_id, "ai_proposal")

        {:ok, {:denied_target, audited_id}} ->
          deny_or_not_found(professional.id, audited_id, "target_behavior")

        {:error, {:error, reason}} ->
          {:error, reason}

        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Edits an AI proposal's displayed text. `encrypted_original_text` is never
  touched — `AIProposal.update_changeset/2` structurally excludes it from
  its cast list (design D3, write-once).
  """
  @spec edit_ai_proposal(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, AIProposal.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def edit_ai_proposal(%Professional{} = professional, patient_id, proposal_id, text) do
    with_patient(professional, patient_id, fn patient, keyring ->
      case Repo.get_by(AIProposal, id: proposal_id, patient_id: patient.id) do
        nil ->
          tombstone_gate(professional.id, proposal_id, "ai_proposal")

        proposal ->
          with {:ok, ciphertext} <- PatientVault.encrypt(text, keyring.clinical_record_dek) do
            commit_ai_proposal_update(
              professional,
              proposal,
              %{encrypted_text: ciphertext, encryption_version: 2, status: "edited"},
              "ai_proposal_edited"
            )
          end
      end
    end)
  end

  @doc """
  Discards an AI proposal — a soft `status` transition (design D5). The row
  is kept; no delete function exists for `AIProposal`.
  """
  @spec discard_ai_proposal(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, AIProposal.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def discard_ai_proposal(%Professional{} = professional, patient_id, proposal_id) do
    with_patient(professional, patient_id, fn patient, _keyring ->
      update_ai_proposal_status(
        professional,
        patient,
        proposal_id,
        %{status: "discarded"},
        "ai_proposal_discarded"
      )
    end)
  end

  @doc """
  Creates or replaces the single functional-analysis draft for a target
  behavior (design A7/D4: one row per `target_behavior_id`, enforced by a
  unique index). `on_conflict` replaces the body and last-editor fields in
  place — no version history, no second row.
  """
  @spec upsert_functional_analysis_draft(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t()
        ) ::
          {:ok, FunctionalAnalysisDraft.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t() | term()}
  def upsert_functional_analysis_draft(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        body
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      Repo.transaction(fn ->
        case lock_and_validate_target_behavior(professional, patient, target_behavior_id) do
          {:ok, _target_behavior} ->
            existing_draft =
              Repo.get_by(FunctionalAnalysisDraft,
                target_behavior_id: target_behavior_id,
                patient_id: patient.id
              )

            next_lock_version =
              if existing_draft, do: (existing_draft.lock_version || 0) + 1, else: 1

            case persist_functional_analysis_draft(
                   professional,
                   patient,
                   target_behavior_id,
                   body,
                   keyring,
                   next_lock_version
                 ) do
              {:ok, draft} -> draft
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, {:denied_target, audited_id}} ->
            {:denied_target, audited_id}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:denied_target, audited_id}} ->
          log_denied_audit(professional.id, audited_id, "target_behavior")
          {:error, :not_found}

        {:ok, draft} ->
          {:ok, draft}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Normalizes string-keyed E-O-R-C parameters and saves their deterministic
  canonical JSON representation through the existing encrypted draft
  transaction. The canonical serialization is the plaintext encrypted into
  `FunctionalAnalysisDraft.encrypted_body`, so existing decrypted-body RAG
  indexing continues to receive that same complete representation.

  Supports optimistic concurrency: `opts` can provide `:expected_lock_version`
  (or `"lock_version"` in `params`). If provided, rejects stale updates with
  `{:error, :conflict}`. On success, increments `lock_version`.

  A legal-deletion tombstone is never replaced with a new draft.
  """
  @spec upsert_functional_analysis_content(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          map(),
          keyword()
        ) ::
          {:ok, FunctionalAnalysisDraft.t()}
          | {:error,
             :unauthorized
             | :not_found
             | :legally_deleted
             | :conflict
             | Ecto.Changeset.t()
             | term()}
  def upsert_functional_analysis_content(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        params,
        opts \\ []
      )
      when is_map(params) and is_list(opts) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      Repo.transaction(fn ->
        case lock_and_validate_target_behavior(professional, patient, target_behavior_id) do
          {:ok, _target_behavior} ->
            case Tombstone.for_target_behavior(target_behavior_id, "functional_analysis_draft") do
              %Tombstone{resource_id: resource_id} ->
                {:denied_tombstone, resource_id}

              nil ->
                existing_draft =
                  Repo.get_by(FunctionalAnalysisDraft,
                    target_behavior_id: target_behavior_id,
                    patient_id: patient.id
                  )

                case check_draft_lock_version(existing_draft, params, opts) do
                  {:ok, next_lock_version} ->
                    body =
                      params
                      |> FunctionalAnalysisContent.new()
                      |> FunctionalAnalysisContent.serialize()

                    case persist_functional_analysis_draft(
                           professional,
                           patient,
                           target_behavior_id,
                           body,
                           keyring,
                           next_lock_version
                         ) do
                      {:ok, draft} -> draft
                      {:error, reason} -> Repo.rollback(reason)
                    end

                  {:error, :conflict} ->
                    Repo.rollback({:error, :conflict})
                end
            end

          {:error, {:denied_target, audited_id}} ->
            {:denied_target, audited_id}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, {:denied_tombstone, resource_id}} ->
          log_denied_audit(professional.id, resource_id, "functional_analysis_draft")
          {:error, :legally_deleted}

        {:ok, {:denied_target, audited_id}} ->
          log_denied_audit(professional.id, audited_id, "target_behavior")
          {:error, :not_found}

        {:ok, draft} ->
          {:ok, draft}

        {:error, {:error, :conflict}} ->
          {:error, :conflict}

        {:error, :conflict} ->
          {:error, :conflict}

        {:error, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Registers the current persisted functional-analysis draft as an immutable
  version. The caller must present its exact lock version and a nonblank
  change note (at most 500 graphemes). The TargetBehavior row is locked in
  the same transaction used by draft writes, serializing revision checks and
  per-target numbering. The already-encrypted draft body is copied verbatim;
  only the trimmed note is encrypted here.
  """
  @spec register_functional_analysis_version(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          String.t()
        ) :: {:ok, FunctionalAnalysisVersion.t()} | {:error, term()}
  def register_functional_analysis_version(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        expected_lock_version,
        change_note
      ) do
    with {:ok, trimmed_note} <- validate_version_change_note(change_note) do
      with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
        Repo.transaction(fn ->
          case lock_and_validate_target_behavior(professional, patient, target_behavior_id) do
            {:ok, _target} ->
              case Tombstone.for_target_behavior(target_behavior_id, "functional_analysis_draft") do
                %Tombstone{resource_id: resource_id} ->
                  {:denied_tombstone, resource_id}

                nil ->
                  register_locked_functional_analysis_version(
                    professional,
                    patient,
                    target_behavior_id,
                    expected_lock_version,
                    trimmed_note,
                    keyring
                  )
              end

            {:error, {:denied_target, audited_id}} ->
              {:denied_target, audited_id}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, {:denied_tombstone, resource_id}} ->
            log_denied_audit(professional.id, resource_id, "functional_analysis_draft")
            {:error, :legally_deleted}

          {:ok, {:denied_target, audited_id}} ->
            log_denied_audit(professional.id, audited_id, "target_behavior")
            {:error, :not_found}

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:ok, version} ->
            {:ok, version}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  defp validate_version_change_note(note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      trimmed == "" -> {:error, :invalid_change_note}
      String.length(trimmed) > 500 -> {:error, :invalid_change_note}
      true -> {:ok, trimmed}
    end
  end

  defp validate_version_change_note(_), do: {:error, :invalid_change_note}

  defp register_locked_functional_analysis_version(
         professional,
         patient,
         target_behavior_id,
         expected_lock_version,
         change_note,
         keyring
       ) do
    case Repo.get_by(FunctionalAnalysisDraft,
           patient_id: patient.id,
           target_behavior_id: target_behavior_id
         ) do
      nil ->
        {:error, :draft_not_found}

      %FunctionalAnalysisDraft{} = draft
      when is_integer(expected_lock_version) and expected_lock_version > 0 ->
        if draft.lock_version != expected_lock_version do
          {:error, :conflict}
        else
          # Decrypt/re-encrypt before consuming a sequence number so a
          # failure leaves no version row and no gap.
          with {:ok, encrypted_body} <- version_body_for(draft, keyring),
               {:ok, encrypted_note} <-
                 PatientVault.encrypt(change_note, keyring.clinical_record_dek),
               {:ok, version_number} <-
                 increment_functional_analysis_version_sequence(target_behavior_id) do
            changeset =
              FunctionalAnalysisVersion.changeset(%FunctionalAnalysisVersion{}, %{
                encrypted_body: encrypted_body,
                encrypted_change_note: encrypted_note,
                encryption_version: 2,
                version_number: version_number,
                draft_id: draft.id,
                patient_id: patient.id,
                professional_id: professional.id,
                target_behavior_id: target_behavior_id
              })

            Ecto.Multi.new()
            |> Ecto.Multi.insert(:record, changeset)
            |> Ecto.Multi.insert(:audit, fn %{record: record} ->
              Audit.changeset(%Audit{
                professional_id: professional.id,
                action: "functional_analysis_version_registered",
                resource_type: "functional_analysis_version",
                resource_id: record.id,
                outcome: "success"
              })
            end)
            |> Oban.insert(:outbox_event, fn %{record: record} ->
              Outbox.event("functional_analysis_version_registered", record)
            end)
            |> Repo.transaction()
            |> case do
              {:ok, %{record: record}} -> record
              {:error, _step, reason, _changes} -> Repo.rollback(reason)
            end
          end
        end

      %FunctionalAnalysisDraft{} ->
        {:error, :conflict}
    end
  end

  # Every version row is stamped `encryption_version: 2`, so its body must be
  # under the clinical-record DEK. A v2 draft is copied verbatim; a legacy v1
  # draft (patient DEK) is decrypted and re-encrypted. Undecryptable drafts
  # fail registration instead of storing an unreadable version.
  defp version_body_for(%FunctionalAnalysisDraft{encryption_version: 2} = draft, _keyring),
    do: {:ok, draft.encrypted_body}

  defp version_body_for(%FunctionalAnalysisDraft{} = draft, keyring) do
    with {:ok, plaintext} <- PatientVault.decrypt(draft.encrypted_body, dek_for(draft, keyring)) do
      PatientVault.encrypt(plaintext, keyring.clinical_record_dek)
    end
  end

  defp increment_functional_analysis_version_sequence(target_behavior_id) do
    case Repo.update_all(
           from(target in TargetBehavior, where: target.id == ^target_behavior_id),
           inc: [functional_analysis_version_sequence: 1]
         ) do
      {1, _} ->
        target = Repo.get!(TargetBehavior, target_behavior_id)
        {:ok, target.functional_analysis_version_sequence}

      {0, _} ->
        {:error, :target_not_found}
    end
  end

  @doc "Lists authorized immutable functional-analysis versions in registration order, decrypting body and change note."
  @spec list_functional_analysis_versions(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [FunctionalAnalysisVersion.t()]} | {:error, term()}
  def list_functional_analysis_versions(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      versions =
        FunctionalAnalysisVersion
        |> where([version], version.patient_id == ^patient.id)
        |> where([version], version.target_behavior_id == ^target_behavior_id)
        |> order_by([version], asc: version.version_number)
        |> preload(:professional)
        |> Repo.all()

      {:ok, Enum.map(versions, &decrypt_functional_analysis_version(&1, keyring))}
    end)
  end

  @doc """
  Lists authorized version summaries: metadata plus the decrypted change
  note only. `body`/`encrypted_body` are never selected or decrypted
  (GitHub #364) — this is the body-free listing used by the read-only
  version browser.
  """
  @spec list_functional_analysis_version_summaries(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) :: {:ok, [FunctionalAnalysisVersion.t()]} | {:error, term()}
  def list_functional_analysis_version_summaries(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      versions =
        FunctionalAnalysisVersion
        |> where([version], version.patient_id == ^patient.id)
        |> where([version], version.target_behavior_id == ^target_behavior_id)
        |> order_by([version], asc: version.version_number)
        |> select(
          [version],
          struct(version, [
            :id,
            :version_number,
            :encryption_version,
            :encrypted_change_note,
            :professional_id,
            :target_behavior_id,
            :patient_id,
            :inserted_at
          ])
        )
        |> preload(:professional)
        |> Repo.all()

      {:ok, Enum.map(versions, &decrypt_functional_analysis_version_note(&1, keyring))}
    end)
  end

  defp decrypt_functional_analysis_version_note(version, keyring) do
    %{
      version
      | change_note:
          decrypt_or_placeholder(version.encrypted_change_note, dek_for(version, keyring))
    }
  end

  @doc "Loads and decrypts one historical version scoped to its authorized patient and target behavior."
  @spec get_functional_analysis_version(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) :: {:ok, FunctionalAnalysisVersion.t()} | {:error, term()}
  def get_functional_analysis_version(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        version_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      with {:ok, uuid} <- Ecto.UUID.cast(version_id),
           %FunctionalAnalysisVersion{} = version <-
             Repo.get_by(FunctionalAnalysisVersion,
               id: uuid,
               patient_id: patient.id,
               target_behavior_id: target_behavior_id
             ) do
        {:ok,
         version |> Repo.preload(:professional) |> decrypt_functional_analysis_version(keyring)}
      else
        _ ->
          log_denied_audit(
            professional.id,
            cast_audit_id(version_id),
            "functional_analysis_version"
          )

          {:error, :not_found}
      end
    end)
  end

  defp decrypt_functional_analysis_version(version, keyring) do
    dek = dek_for(version, keyring)

    body = decrypt_or_placeholder(version.encrypted_body, dek)
    change_note = decrypt_or_placeholder(version.encrypted_change_note, dek)
    %{version | body: body, change_note: change_note}
  end

  defp cast_audit_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @doc """
  Read-only lookup of the single functional-analysis draft for a target
  behavior (design A7/D4 — at most one row per `target_behavior_id`).
  Returns `{:ok, nil}` when no draft has been saved yet. No audit row is
  written (mirrors `review_timeline/3` — read access to the workbench is
  not logged). Added for PR3's `TargetBehaviorLive.Review`: the draft
  form needs its current content to remain editable in place, and no
  getter existed in design's context API table (PR2a only shipped the
  upsert) — a minimal, symmetrical read addition rather than reaching
  into `Repo`/`PatientVault` from the web layer.

  Returns `{:ok, {:legally_deleted, deleted_at}}` instead of `{:ok, nil}`
  when the draft was legally deleted (BR10, sdd/clinical-record-retention,
  GitHub #197) — an explicit content-free tombstone answer, distinct from
  "no draft was ever saved", so the caller never silently renders an empty
  form for a deleted draft as if nothing had happened.
  """
  @spec get_functional_analysis_draft(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, FunctionalAnalysisDraft.t() | nil}
          | {:ok, {:legally_deleted, DateTime.t()}}
          | {:error, :unauthorized | :not_found | term()}
  def get_functional_analysis_draft(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      case Repo.get_by(FunctionalAnalysisDraft,
             target_behavior_id: target_behavior_id,
             patient_id: patient.id
           ) do
        nil ->
          case Tombstone.for_target_behavior(target_behavior_id, "functional_analysis_draft") do
            %Tombstone{deleted_at: deleted_at} -> {:ok, {:legally_deleted, deleted_at}}
            nil -> {:ok, nil}
          end

        draft ->
          {:ok,
           %{draft | body: decrypt_or_placeholder(draft.encrypted_body, dek_for(draft, keyring))}}
      end
    end)
  end

  @doc """
  Retrieves normalized E-O-R-C content from the existing draft lookup.
  Legacy plaintext is preserved byte-for-byte only in `previous_notes`; no
  clinical meaning is inferred. Missing and legally deleted drafts retain the
  compatibility API's distinct return values.
  """
  @spec get_functional_analysis_content(
          Professional.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t()
        ) ::
          {:ok, FunctionalAnalysisContent.t() | nil}
          | {:ok, {:legally_deleted, DateTime.t()}}
          | {:error, :unauthorized | :not_found | term()}
  def get_functional_analysis_content(
        %Professional{} = professional,
        patient_id,
        target_behavior_id
      ) do
    case get_functional_analysis_draft(professional, patient_id, target_behavior_id) do
      {:ok, %FunctionalAnalysisDraft{body: body}} ->
        {_format, content} = FunctionalAnalysisContent.parse(body)
        {:ok, content}

      other ->
        other
    end
  end

  @doc """
  Read-only chronological merge of a target behavior's review timeline:
  cited consultation evidence, clinician observations, and AI proposals
  (design A5). No audit row is written — read access to the timeline is not
  logged (design's context API table lists no audit action for this
  function).

  The three tables are queried separately, decrypted per row under the
  patient's DEK, and merged in Elixir by `{occurred_at, kind_rank, id}` —
  a SQL `UNION` is not possible because each kind encrypts under a
  differently-named column (design A5). `kind_rank` (evidence 0,
  observation 1, proposal 2) is a deterministic tiebreak for items sharing
  the same `occurred_at`.

  Discarded AI proposals are **not** filtered out here (design D5 stays
  observable) — the caller decides presentation. Each evidence item's
  `source` field is resolved via `SourceRef.resolve_many/1` and is
  `:unavailable` when the cited source row has since been deleted or
  cryptographically erased; the item still renders from its own stored,
  encrypted excerpt (design A3).

  Legally deleted evidence/observation/proposal rows (BR10,
  sdd/clinical-record-retention, GitHub #197) are merged in from
  `Alethea.ClinicalRecord.Tombstone` by `target_behavior_id`, as a
  distinct `:legally_deleted` kind carrying only `occurred_at` (the
  tombstone's `deleted_at`) and `resource_type` — never the erased
  content. A legally deleted `functional_analysis_draft` tombstone is
  intentionally excluded here: it is not a timeline item, it is surfaced
  through `get_functional_analysis_draft/3` instead.
  """
  @spec review_timeline(Professional.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [map()]} | {:error, :unauthorized | :not_found | term()}
  def review_timeline(%Professional{} = professional, patient_id, target_behavior_id) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn _patient, keyring ->
      evidence =
        ConsultationEvidence
        |> where([e], e.target_behavior_id == ^target_behavior_id)
        |> order_by([e], asc: e.occurred_at)
        |> Repo.all()

      observations =
        ClinicianObservation
        |> where([o], o.target_behavior_id == ^target_behavior_id)
        |> order_by([o], asc: o.occurred_at)
        |> Repo.all()

      proposals =
        AIProposal
        |> where([p], p.target_behavior_id == ^target_behavior_id)
        |> order_by([p], asc: p.occurred_at)
        |> Repo.all()

      tombstones =
        Tombstone
        |> where([t], t.target_behavior_id == ^target_behavior_id)
        |> where(
          [t],
          t.resource_type in ~w(consultation_evidence clinician_observation ai_proposal)
        )
        |> Repo.all()

      source_refs =
        evidence
        |> Enum.map(&{&1.source_kind, &1.source_id})
        |> SourceRef.resolve_many()

      timeline =
        (Enum.map(evidence, &evidence_item(&1, keyring, source_refs)) ++
           Enum.map(observations, &observation_item(&1, keyring)) ++
           Enum.map(proposals, &proposal_item(&1, keyring)) ++
           Enum.map(tombstones, &tombstone_item/1))
        |> Enum.sort_by(&{&1.occurred_at, kind_rank(&1.kind), &1.id})

      {:ok, timeline}
    end)
  end

  defp evidence_item(%ConsultationEvidence{} = evidence, keyring, source_refs) do
    %{
      id: evidence.id,
      kind: :consultation_evidence,
      occurred_at: evidence.occurred_at,
      text: decrypt_or_placeholder(evidence.encrypted_excerpt, dek_for(evidence, keyring)),
      source: Map.get(source_refs, {evidence.source_kind, evidence.source_id}, :unavailable),
      speaker: evidence.speaker,
      audio_start_seconds: evidence.audio_start_seconds,
      audio_end_seconds: evidence.audio_end_seconds
    }
  end

  defp observation_item(%ClinicianObservation{} = observation, keyring) do
    %{
      id: observation.id,
      kind: :clinician_observation,
      occurred_at: observation.occurred_at,
      text: decrypt_or_placeholder(observation.encrypted_body, dek_for(observation, keyring))
    }
  end

  defp proposal_item(%AIProposal{} = proposal, keyring) do
    %{
      id: proposal.id,
      kind: :ai_proposal,
      occurred_at: proposal.occurred_at,
      text: decrypt_or_placeholder(proposal.encrypted_text, dek_for(proposal, keyring)),
      status: proposal.status
    }
  end

  defp tombstone_item(%Tombstone{} = tombstone) do
    %{
      id: tombstone.id,
      kind: :legally_deleted,
      occurred_at: tombstone.deleted_at,
      resource_type: tombstone.resource_type
    }
  end

  defp kind_rank(:consultation_evidence), do: 0
  defp kind_rank(:clinician_observation), do: 1
  defp kind_rank(:ai_proposal), do: 2
  defp kind_rank(:legally_deleted), do: 3

  defp decrypt_or_placeholder(ciphertext, dek) do
    case PatientVault.decrypt(ciphertext, dek) do
      {:ok, plaintext} -> plaintext
      {:error, _reason} -> "[Error al descifrar]"
    end
  end

  # Reads and decrypts the current draft body for a target behavior,
  # returning an empty string when no draft exists yet. Used by
  # `accept_ai_proposal_into_draft/4` to build the merged body from DB
  # state instead of socket state (#291).
  defp load_current_draft_body(patient_id, target_behavior_id, keyring) do
    case Repo.get_by(FunctionalAnalysisDraft,
           target_behavior_id: target_behavior_id,
           patient_id: patient_id
         ) do
      nil ->
        ""

      draft ->
        case PatientVault.decrypt(draft.encrypted_body, dek_for(draft, keyring)) do
          {:ok, body} -> body
          {:error, _reason} -> ""
        end
    end
  end

  # Appends `proposal_text` to `current_body`, separated by a newline.
  # Returns a trimmed string so we never get leading/trailing whitespace.
  defp merge_draft_body("", proposal_text), do: String.trim(proposal_text)

  defp merge_draft_body(current_body, proposal_text) do
    String.trim(current_body <> "\n" <> proposal_text)
  end

  defp update_ai_proposal_status(professional, patient, proposal_id, attrs, action) do
    case Repo.get_by(AIProposal, id: proposal_id, patient_id: patient.id) do
      nil ->
        tombstone_gate(professional.id, proposal_id, "ai_proposal")

      proposal ->
        commit_ai_proposal_update(professional, proposal, attrs, action)
    end
  end

  defp commit_ai_proposal_update(professional, proposal, attrs, action) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:record, AIProposal.update_changeset(proposal, attrs))
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: action,
        resource_type: "ai_proposal",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Oban.insert(:outbox_event, fn %{record: record} -> Outbox.event(action, record) end)
    |> Repo.transaction()
    |> finalize_record_multi()
  end

  defp persist_functional_analysis_draft(
         professional,
         patient,
         target_behavior_id,
         body,
         keyring,
         lock_version
       ) do
    with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
      changeset =
        FunctionalAnalysisDraft.changeset(%FunctionalAnalysisDraft{}, %{
          encrypted_body: ciphertext,
          encryption_version: 2,
          lock_version: lock_version,
          patient_id: patient.id,
          professional_id: professional.id,
          target_behavior_id: target_behavior_id
        })

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:record, changeset,
        on_conflict:
          {:replace,
           [:encrypted_body, :encryption_version, :lock_version, :professional_id, :updated_at]},
        conflict_target: :target_behavior_id,
        returning: true
      )
      |> Ecto.Multi.insert(:audit, fn %{record: record} ->
        Audit.changeset(%Audit{
          professional_id: professional.id,
          action: "functional_analysis_draft_saved",
          resource_type: "functional_analysis_draft",
          resource_id: record.id,
          outcome: "success"
        })
      end)
      |> Oban.insert(:outbox_event, fn %{record: record} ->
        Outbox.event("functional_analysis_draft_saved", record)
      end)
      |> Repo.transaction()
      |> finalize_record_multi()
    end
  end

  defp check_draft_lock_version(existing_draft, params, opts) do
    case extract_expected_lock_version(params, opts) do
      {:provided, expected} ->
        cond do
          not is_nil(existing_draft) and existing_draft.lock_version != expected ->
            {:error, :conflict}

          is_nil(existing_draft) and expected not in [nil, 0, 1] ->
            {:error, :conflict}

          true ->
            next_version = if existing_draft, do: (existing_draft.lock_version || 0) + 1, else: 1
            {:ok, next_version}
        end

      :not_provided ->
        next_version = if existing_draft, do: (existing_draft.lock_version || 0) + 1, else: 1
        {:ok, next_version}
    end
  end

  defp extract_expected_lock_version(params, opts) do
    cond do
      Keyword.has_key?(opts, :expected_lock_version) ->
        {:provided, parse_lock_version(Keyword.get(opts, :expected_lock_version))}

      Keyword.has_key?(opts, :lock_version) ->
        {:provided, parse_lock_version(Keyword.get(opts, :lock_version))}

      is_map(params) and Map.has_key?(params, "lock_version") ->
        {:provided, parse_lock_version(Map.get(params, "lock_version"))}

      is_map(params) and Map.has_key?(params, :lock_version) ->
        {:provided, parse_lock_version(Map.get(params, :lock_version))}

      true ->
        :not_provided
    end
  end

  defp parse_lock_version(nil), do: nil
  defp parse_lock_version(version) when is_integer(version), do: version

  defp parse_lock_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {int, ""} -> int
      _ -> :invalid
    end
  end

  defp parse_lock_version(_), do: :invalid

  defp finalize_record_multi(transaction_result) do
    case transaction_result do
      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record multi failed at #{step}")
        {:error, reason}
    end
  end

  defp deny_access(professional_id, patient_id) do
    log_denied_audit(professional_id, patient_id, "patient")
    {:error, :unauthorized}
  end

  # D4 gate — every mutable write's `nil` branch (a `Repo.get_by/2` scoped
  # by `patient_id` miss) reaches here. A miss now means one of two things:
  # the id never existed (`:not_found`), or the resource was legally
  # deleted (`:legally_deleted`) — an explicit policy answer, never an
  # indistinguishable `:not_found` (D4's stated rationale).
  @spec tombstone_gate(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:error, :legally_deleted | :not_found}
  defp tombstone_gate(professional_id, resource_id, resource_type) do
    case Tombstone.for_resource(resource_type, resource_id) do
      %Tombstone{} ->
        deny_access(professional_id, resource_id, resource_type)

      nil ->
        {:error, :not_found}
    end
  end

  # Post-transaction miss handler for writes whose lookup already ran inside a
  # row-locking transaction. A tombstone makes the miss an explicit
  # `:legally_deleted`; any other miss stays `:not_found`. Either way exactly one
  # denied audit row is written, and the tombstone lookup stays outside the
  # transaction. A nil id (malformed input) cannot match a tombstone.
  defp deny_or_not_found(professional_id, resource_id, resource_type) do
    tombstone =
      if is_nil(resource_id), do: nil, else: Tombstone.for_resource(resource_type, resource_id)

    case tombstone do
      %Tombstone{} ->
        deny_access(professional_id, resource_id, resource_type)

      nil ->
        log_denied_audit(professional_id, resource_id, resource_type)
        {:error, :not_found}
    end
  end

  defp deny_access(professional_id, resource_id, resource_type) do
    log_denied_audit(professional_id, resource_id, resource_type)
    {:error, :legally_deleted}
  end

  defp log_denied_audit(professional_id, resource_id, resource_type) do
    case Audit.log_denied(professional_id, resource_id, resource_type) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("clinical_record log_denied failed: #{inspect(reason)}")
    end
  end

  defp insert_target_behavior(professional, patient, ciphertext) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :record,
      TargetBehavior.changeset(%TargetBehavior{}, %{
        patient_id: patient.id,
        professional_id: professional.id,
        encrypted_description: ciphertext
      })
    )
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: "target_behavior_created",
        resource_type: "target_behavior",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Oban.insert(:outbox_event, fn %{record: record} ->
      Outbox.event("target_behavior_created", record)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record multi failed at #{step}")
        {:error, reason}
    end
  end

  defp insert_clinical_note(professional, patient, ciphertext) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :record,
      ClinicalNote.changeset(%ClinicalNote{}, %{
        patient_id: patient.id,
        professional_id: professional.id,
        encrypted_body: ciphertext
      })
    )
    |> Ecto.Multi.insert(:audit, fn %{record: record} ->
      Audit.changeset(%Audit{
        professional_id: professional.id,
        action: "clinical_note_created",
        resource_type: "clinical_note",
        resource_id: record.id,
        outcome: "success"
      })
    end)
    |> Oban.insert(:outbox_event, fn %{record: record} ->
      Outbox.event("clinical_note_created", record)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{record: record}} ->
        {:ok, record}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record multi failed at #{step}")
        {:error, reason}
    end
  end
end
