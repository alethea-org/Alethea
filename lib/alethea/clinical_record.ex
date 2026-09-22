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
    FunctionalAnalysisDraft,
    Outbox,
    TargetBehavior
  }

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
  Cites a source-derived fact (a `clinical_note` or a `message`) onto the
  review timeline. Copies and encrypts the exact `excerpt` under the
  patient's DEK at citation time (design A3) — `attrs` carries `source_kind`,
  `source_id` (untyped, no FK — design A2), `excerpt`, and `occurred_at`.
  """
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
      with {:ok, ciphertext} <- PatientVault.encrypt(excerpt, keyring.clinical_record_dek) do
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :record,
          ConsultationEvidence.changeset(%ConsultationEvidence{}, %{
            source_kind: source_kind,
            source_id: source_id,
            encrypted_excerpt: ciphertext,
            encryption_version: 2,
            occurred_at: occurred_at,
            patient_id: patient.id,
            professional_id: professional.id,
            target_behavior_id: target_behavior_id
          })
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
    end)
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
          | {:error, :unauthorized | Ecto.Changeset.t() | term()}
  def upsert_functional_analysis_draft(
        %Professional{} = professional,
        patient_id,
        target_behavior_id,
        body
      ) do
    with_target_behavior(professional, patient_id, target_behavior_id, fn patient, keyring ->
      with {:ok, ciphertext} <- PatientVault.encrypt(body, keyring.clinical_record_dek) do
        changeset =
          FunctionalAnalysisDraft.changeset(%FunctionalAnalysisDraft{}, %{
            encrypted_body: ciphertext,
            encryption_version: 2,
            patient_id: patient.id,
            professional_id: professional.id,
            target_behavior_id: target_behavior_id
          })

        Ecto.Multi.new()
        |> Ecto.Multi.insert(:record, changeset,
          on_conflict:
            {:replace, [:encrypted_body, :encryption_version, :professional_id, :updated_at]},
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
    end)
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
      source: Map.get(source_refs, {evidence.source_kind, evidence.source_id}, :unavailable)
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
