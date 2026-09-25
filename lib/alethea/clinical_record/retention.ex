defmodule Alethea.ClinicalRecord.Retention do
  @moduledoc """
  Per-record retention eligibility, the legal-deletion primitive, and the
  BR11 whole-patient iteration (design's `Alethea.ClinicalRecord.Retention`,
  sdd/clinical-record-retention, GitHub #197, Phase 3/Slice C).

  Table iteration order (`@tables`) deliberately lists every table that
  carries a `target_behavior_id` FK with `on_delete: :delete_all`
  (`ConsultationEvidence`, `ClinicianObservation`, `AIProposal`,
  `FunctionalAnalysisDraft`) BEFORE `TargetBehavior` itself, and
  `ClinicalNote` (no such FK) anywhere. This ordering means
  `legally_delete_patient_record/3`'s sequential iteration always retires
  a `TargetBehavior`'s children — each with its own tombstone, audit row,
  and RAG purge — before the parent, so Postgres's FK cascade on the
  parent's own hard-delete never has a child row left to silently sweep
  away without going through this module. **This mitigation does not
  extend to `AletheaJobs.RetentionSweepWorker`**: the sweep evaluates each
  table's eligibility independently (spec: "no patient-wide MAX
  aggregate"), so a `TargetBehavior` past its own retention threshold can
  still be swept while a same-patient child row is not yet eligible;
  deleting the parent would then cascade-delete that still-active child
  with no tombstone, no audit row, and no RAG purge. This is a known,
  flagged risk inherited from the pre-existing `on_delete: :delete_all`
  FKs (sdd/alethea/issue-195-clinical-review-workbench) — resolving it
  (e.g. deferring a parent's sweep-deletion while active children exist)
  is a design decision out of this task list's scope (3.1-3.13) and is
  not silently implemented here.
  """

  import Ecto.Query
  require Logger

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional

  alias Alethea.ClinicalRecord.{
    AIProposal,
    Audit,
    ClinicalNote,
    ClinicianObservation,
    ConsultationEvidence,
    FunctionalAnalysisDraft,
    Lifecycle,
    Outbox,
    SessionTranscript,
    TargetBehavior,
    Tombstone
  }

  alias Alethea.Repo

  @type resource_ref :: {resource_type :: String.t(), resource_id :: Ecto.UUID.t()}

  # {schema, resource_type literal, retention timestamp field (AD2)}.
  # Order matters — see moduledoc.
  @tables [
    {ConsultationEvidence, "consultation_evidence", :inserted_at},
    {ClinicianObservation, "clinician_observation", :updated_at},
    {AIProposal, "ai_proposal", :updated_at},
    {FunctionalAnalysisDraft, "functional_analysis_draft", :updated_at},
    {ClinicalNote, "clinical_note", :inserted_at},
    {SessionTranscript, "session_transcript", :inserted_at},
    {TargetBehavior, "target_behavior", :inserted_at}
  ]

  @resource_types Enum.map(@tables, fn {_schema, resource_type, _field} -> resource_type end)

  @doc """
  Every eligible `resource_type` literal this module knows about — the
  same seven `Alethea.ClinicalRecord.Audit`/`Tombstone` resource types.
  """
  @spec resource_types() :: [String.t()]
  def resource_types, do: @resource_types

  @doc """
  Eligibility query for one table (design's Interfaces/Contracts section).
  `own_last_action + max(global_baseline, patient.stricter_minimum) <= now`
  (spec's Per-Record Retention Eligibility requirement), computed entirely
  in SQL against a `left_join` on `Lifecycle` — a patient with no lifecycle
  row (`left_join` miss ⇒ `NULL`) is still eligible (`is_nil/1` on a `NULL`
  hold is `true`; `COALESCE` on a `NULL` override falls back to baseline).

  The `select:` clause loads **identifiers only** — `resource_type`,
  `resource_id`, `patient_id`, `professional_id`, `retention_at` — never
  an `encrypted_*` column. This is the mechanical proof the sweep can
  never decrypt anything.
  """
  @spec eligible_records(module(), keyword()) :: [
          %{
            resource_type: String.t(),
            resource_id: Ecto.UUID.t(),
            patient_id: Ecto.UUID.t(),
            professional_id: Ecto.UUID.t(),
            retention_at: DateTime.t()
          }
        ]
  def eligible_records(schema, opts \\ []) when is_atom(schema) do
    {_schema, resource_type, timestamp_field} = table_config!(schema)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    baseline_days = Keyword.get(opts, :baseline_days, baseline_days())
    batch_size = Keyword.get(opts, :batch_size, 500)

    schema
    |> join(:left, [r], l in Lifecycle, on: l.patient_id == r.patient_id)
    |> where([r, l], is_nil(l.legal_hold_at))
    |> where(
      [r, l],
      fragment(
        "? <= ? - make_interval(days => ?)",
        field(r, ^timestamp_field),
        type(^now, :naive_datetime),
        fragment(
          "GREATEST(?, COALESCE(?, ?))",
          ^baseline_days,
          l.retention_minimum_days,
          ^baseline_days
        )
      )
    )
    |> order_by([r], asc: field(r, ^timestamp_field), asc: r.id)
    |> limit(^batch_size)
    |> select([r], %{
      resource_type: ^resource_type,
      resource_id: r.id,
      patient_id: r.patient_id,
      professional_id: r.professional_id,
      retention_at: field(r, ^timestamp_field)
    })
    |> Repo.all()
  end

  @doc """
  `eligible_records/2` across all seven tables, flattened. Used by
  `AletheaJobs.RetentionSweepWorker` for both its dry-run report and its
  real sweep.
  """
  @spec eligible_records_all_tables(keyword()) :: [map()]
  def eligible_records_all_tables(opts \\ []) do
    Enum.flat_map(@tables, fn {schema, _resource_type, _field} ->
      eligible_records(schema, opts)
    end)
  end

  @doc """
  Legal-deletion primitive — one `Ecto.Multi` per record (design's Data
  Flow / Interfaces sections): `:record` (`delete_all` by id, identifiers
  loaded only), `:tombstone`, `:audit` (attributed by `trigger` — AD5:
  `"sweep"` attributes to the record's own author, `"manual"` to the
  acting professional), `:rag_purge` (`Oban.insert/3` of
  `Outbox.tombstone_event/4`), `:crypto_erasure` (`Multi.run/3`, fires
  the terminal `Accounts.destroy_clinical_record_dek/1` only when the
  patient's remaining rows across all seven tables reach zero — D1
  verbatim).

  `opts`: `actor: %Professional{} | :system` (default `:system`),
  `trigger: "sweep" | "manual"` (required).
  """
  @spec legally_delete_record(resource_ref(), keyword()) ::
          {:ok, Tombstone.t()}
          | {:error, :not_found | :legal_hold_active | :already_deleted | term()}
  def legally_delete_record({resource_type, resource_id}, opts \\ [])
      when is_binary(resource_type) do
    actor = Keyword.get(opts, :actor, :system)
    trigger = Keyword.fetch!(opts, :trigger)
    schema = schema_for!(resource_type)

    case identifiers_for(schema, resource_id) do
      nil ->
        {:error, :not_found}

      ids ->
        cond do
          Tombstone.for_resource(resource_type, resource_id) ->
            {:error, :already_deleted}

          Lifecycle.held?(ids.patient_id) ->
            audit_hold_paused(actor, ids, resource_type)
            {:error, :legal_hold_active}

          true ->
            run_deletion_multi(schema, resource_type, ids, actor, trigger)
        end
    end
  end

  @doc """
  BR11 — whole-patient legal deletion, iterating `legally_delete_record/2`
  via a bounded `Enum.reduce_while` over every one of the patient's
  current records (AD4 — **not** one transaction). Authorizes once via
  `Accounts.get_patient_for_professional/2`, checks the legal hold once.
  A mid-iteration failure halts and reports the partial count — already
  -deleted records stay deleted (spec: "not a rollback").
  """
  @spec legally_delete_patient_record(Professional.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), tombstones: [Tombstone.t()]}}
          | {:error, :unauthorized | :legal_hold_active | {:partial, non_neg_integer(), term()}}
  def legally_delete_patient_record(%Professional{} = professional, patient_id, _opts \\ []) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        {:error, :unauthorized}

      patient ->
        if Lifecycle.held?(patient.id) do
          {:error, :legal_hold_active}
        else
          delete_all_patient_records(professional, patient.id)
        end
    end
  end

  defp delete_all_patient_records(professional, patient_id) do
    patient_id
    |> all_resource_refs()
    |> Enum.reduce_while({0, []}, fn ref, {count, tombstones} ->
      case legally_delete_record(ref, actor: professional, trigger: "manual") do
        {:ok, tombstone} -> {:cont, {count + 1, [tombstone | tombstones]}}
        {:error, reason} -> {:halt, {:error, {:partial, count, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      {count, tombstones} -> {:ok, %{deleted: count, tombstones: Enum.reverse(tombstones)}}
    end
  end

  defp all_resource_refs(patient_id) do
    Enum.flat_map(@tables, fn {schema, resource_type, _field} ->
      schema
      |> where([r], r.patient_id == ^patient_id)
      |> select([r], r.id)
      |> Repo.all()
      |> Enum.map(&{resource_type, &1})
    end)
  end

  defp run_deletion_multi(schema, resource_type, ids, actor, trigger) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    audited_professional_id = audited_professional_id(actor, ids.professional_id)
    tombstone_deleted_by_id = tombstone_deleted_by_id(actor)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:record, fn repo, _changes ->
      schema
      |> where([r], r.id == ^ids.id)
      |> repo.delete_all()
      |> case do
        {1, _} -> {:ok, :deleted}
        {0, _} -> {:error, :not_found}
      end
    end)
    |> Ecto.Multi.insert(
      :tombstone,
      Tombstone.changeset(%Tombstone{}, %{
        resource_type: resource_type,
        resource_id: ids.id,
        patient_id: ids.patient_id,
        target_behavior_id: ids.target_behavior_id,
        deleted_at: now,
        deleted_by_id: tombstone_deleted_by_id,
        trigger: trigger
      })
    )
    |> Ecto.Multi.insert(
      :audit,
      Audit.changeset(%Audit{
        professional_id: audited_professional_id,
        action: "clinical_record_legally_deleted",
        resource_type: resource_type,
        resource_id: ids.id,
        outcome: "success"
      })
    )
    |> Oban.insert(
      :rag_purge,
      Outbox.tombstone_event(resource_type, ids.id, ids.patient_id, audited_professional_id)
    )
    |> Ecto.Multi.run(:crypto_erasure, fn repo, _changes ->
      maybe_destroy_key(repo, ids.patient_id, audited_professional_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tombstone: tombstone}} ->
        {:ok, tombstone}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record retention multi failed at #{step}")
        {:error, reason}
    end
  end

  # Fires the terminal crypto-erasure ONLY at zero remaining rows across
  # all seven tables for the patient (D1 verbatim). Runs inside the same
  # transaction as the just-committed `delete_all` (this `Multi.run` is
  # sequenced after it), and the retention queue's concurrency `1` (AD4)
  # is what makes this read-then-act safe against a concurrent sibling
  # deletion racing the same check.
  defp maybe_destroy_key(repo, patient_id, audited_professional_id) do
    if remaining_records_count(repo, patient_id) == 0 do
      case Accounts.destroy_clinical_record_dek(patient_id) do
        {:ok, :destroyed} ->
          %Audit{
            professional_id: audited_professional_id,
            action: "clinical_record_key_destroyed",
            resource_type: "patient",
            resource_id: patient_id,
            outcome: "success"
          }
          |> Audit.changeset()
          |> repo.insert()
          |> case do
            {:ok, _audit} -> {:ok, :destroyed}
            {:error, reason} -> {:error, reason}
          end

        {:ok, :absent} ->
          {:ok, :absent}
      end
    else
      {:ok, :active_records_remain}
    end
  end

  defp remaining_records_count(repo, patient_id) do
    @tables
    |> Enum.map(fn {schema, _resource_type, _field} ->
      schema
      |> where([r], r.patient_id == ^patient_id)
      |> repo.aggregate(:count, :id)
    end)
    |> Enum.sum()
  end

  defp audit_hold_paused(actor, ids, resource_type) do
    Audit.log_denied(audited_professional_id(actor, ids.professional_id), ids.id, resource_type)
  end

  defp audited_professional_id(:system, author_professional_id), do: author_professional_id
  defp audited_professional_id(%Professional{id: id}, _author_professional_id), do: id

  defp tombstone_deleted_by_id(:system), do: nil
  defp tombstone_deleted_by_id(%Professional{id: id}), do: id

  defp table_config!(schema) do
    Enum.find(@tables, fn {table_schema, _rt, _field} -> table_schema == schema end) ||
      raise ArgumentError, "unknown ClinicalRecord.Retention schema: #{inspect(schema)}"
  end

  defp schema_for!(resource_type) do
    Enum.find_value(@tables, fn {schema, rt, _field} -> if rt == resource_type, do: schema end) ||
      raise ArgumentError, "unknown resource_type: #{inspect(resource_type)}"
  end

  # Loads a record's identifiers ONLY — no `encrypted_*` column, ever.
  # `target_behavior_id` is normalized to `nil` for tables that carry no
  # such column (`ClinicalNote`, `SessionTranscript`) and to the row's
  # own `id` for `TargetBehavior` itself (a `TargetBehavior`'s own
  # tombstone must carry its own id so `review_timeline/3` finds it via
  # `target_behavior_id`, mirroring every child schema).
  defp identifiers_for(TargetBehavior, resource_id) do
    case base_identifiers(TargetBehavior, resource_id) do
      nil -> nil
      ids -> %{ids | target_behavior_id: ids.id}
    end
  end

  defp identifiers_for(ClinicalNote, resource_id) do
    base_identifiers(ClinicalNote, resource_id)
  end

  # SessionTranscript carries no `target_behavior_id` FK (#317, F1) — this
  # mirrors the ClinicalNote clause above, not the four-schema clause
  # below.
  defp identifiers_for(SessionTranscript, resource_id) do
    base_identifiers(SessionTranscript, resource_id)
  end

  defp identifiers_for(schema, resource_id)
       when schema in [
              ConsultationEvidence,
              ClinicianObservation,
              AIProposal,
              FunctionalAnalysisDraft
            ] do
    schema
    |> where([r], r.id == ^resource_id)
    |> select([r], %{
      id: r.id,
      patient_id: r.patient_id,
      professional_id: r.professional_id,
      target_behavior_id: r.target_behavior_id
    })
    |> Repo.one()
  end

  defp base_identifiers(schema, resource_id) do
    schema
    |> where([r], r.id == ^resource_id)
    |> select([r], %{id: r.id, patient_id: r.patient_id, professional_id: r.professional_id})
    |> Repo.one()
    |> case do
      nil -> nil
      ids -> Map.put(ids, :target_behavior_id, nil)
    end
  end

  defp baseline_days, do: Application.get_env(:alethea, :retention_baseline_days, 3650)
end
