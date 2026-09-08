defmodule Alethea.ClinicalRecord.Lifecycle do
  @moduledoc """
  Patient-scoped legal-hold and stricter-minimum-retention state (design
  D3, sdd/clinical-record-retention, GitHub #197). One row per patient,
  created lazily on the first hold or retention-minimum write — its
  absence means "no hold, global baseline" everywhere it is joined
  (`left_join` + `coalesce`, see `Alethea.ClinicalRecord.Retention`,
  Slice C).

  Deliberately **not** `patients.status` (design D3): a legal hold is an
  orthogonal, reversible flag, not an account lifecycle state.
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  alias Alethea.Accounts
  alias Alethea.Accounts.Professional
  alias Alethea.ClinicalRecord.Audit
  alias Alethea.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "clinical_record_lifecycles" do
    # NULL = no active hold.
    field :legal_hold_at, :utc_datetime
    field :legal_hold_released_at, :utc_datetime
    # NULL = global baseline (BR7); non-NULL is a per-patient stricter minimum.
    field :retention_minimum_days, :integer

    belongs_to :patient, Alethea.Accounts.Patient
    belongs_to :legal_hold_by, Professional

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(lifecycle, attrs) do
    lifecycle
    |> cast(attrs, [
      :patient_id,
      :legal_hold_at,
      :legal_hold_by_id,
      :legal_hold_released_at,
      :retention_minimum_days
    ])
    |> validate_required([:patient_id])
    |> unique_constraint(:patient_id)
  end

  @doc """
  Applies a per-patient legal hold. Lazily creates the lifecycle row on
  first use. Audits `legal_hold_applied` (spec: "Hold apply and lift are
  audited").
  """
  @spec apply_hold(Professional.t(), Ecto.UUID.t()) ::
          {:ok, t()} | {:error, :unauthorized | term()}
  def apply_hold(%Professional{} = professional, patient_id) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        lifecycle = get_or_create!(patient.id)

        attrs = %{
          legal_hold_at: now(),
          legal_hold_by_id: professional.id,
          legal_hold_released_at: nil
        }

        commit_lifecycle_change(
          lifecycle,
          attrs,
          professional.id,
          patient.id,
          "legal_hold_applied"
        )
    end
  end

  @doc """
  Releases an active per-patient legal hold. Re-exposes each record's own
  already-computed eligibility with no clock reset (spec: "Lifting hold
  re-exposes eligibility") — this module never touches any record's own
  `retention_at` timestamp. Audits `legal_hold_released`.
  """
  @spec release_hold(Professional.t(), Ecto.UUID.t()) ::
          {:ok, t()} | {:error, :unauthorized | term()}
  def release_hold(%Professional{} = professional, patient_id) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        lifecycle = get_or_create!(patient.id)
        attrs = %{legal_hold_at: nil, legal_hold_released_at: now()}

        commit_lifecycle_change(
          lifecycle,
          attrs,
          professional.id,
          patient.id,
          "legal_hold_released"
        )
    end
  end

  @doc """
  Whether `patient_id` currently has an active legal hold. A patient with
  no lifecycle row at all (never held) is `false` — the lazy-row absence
  means "no hold" (design's `left_join` rationale).
  """
  @spec held?(Ecto.UUID.t()) :: boolean()
  def held?(patient_id) do
    case Repo.get_by(__MODULE__, patient_id: patient_id) do
      nil -> false
      %__MODULE__{legal_hold_at: nil} -> false
      %__MODULE__{legal_hold_at: %DateTime{}} -> true
    end
  end

  @doc """
  Sets (or clears, via `nil`) the patient's stricter retention-minimum
  override, in days. Lazily creates the lifecycle row on first use.
  """
  @spec set_retention_minimum(Professional.t(), Ecto.UUID.t(), pos_integer() | nil) ::
          {:ok, t()} | {:error, :unauthorized | term()}
  def set_retention_minimum(%Professional{} = professional, patient_id, days)
      when is_nil(days) or (is_integer(days) and days > 0) do
    case Accounts.get_patient_for_professional(professional.id, patient_id) do
      nil ->
        deny_access(professional.id, patient_id)

      patient ->
        lifecycle = get_or_create!(patient.id)

        lifecycle
        |> changeset(%{retention_minimum_days: days})
        |> Repo.update()
    end
  end

  @doc """
  Effective retention window in days: `max(global_baseline, override)`
  (AD3 — a stricter minimum keeps content **longer**). A `nil` lifecycle
  (no row) or a `nil` override both fall back to the baseline.
  """
  @spec effective_retention_days(t() | nil) :: pos_integer()
  def effective_retention_days(nil), do: baseline_days()
  def effective_retention_days(%__MODULE__{retention_minimum_days: nil}), do: baseline_days()

  def effective_retention_days(%__MODULE__{retention_minimum_days: override}) do
    max(baseline_days(), override)
  end

  defp baseline_days, do: Application.get_env(:alethea, :retention_baseline_days, 3650)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Lazily creates the per-patient row, race-safe via `on_conflict: :nothing`
  # + re-read against the `unique_index([:patient_id])` (design (a)).
  defp get_or_create!(patient_id) do
    case Repo.get_by(__MODULE__, patient_id: patient_id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{patient_id: patient_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :patient_id)

        Repo.get_by!(__MODULE__, patient_id: patient_id)

      lifecycle ->
        lifecycle
    end
  end

  defp commit_lifecycle_change(lifecycle, attrs, professional_id, patient_id, action) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:lifecycle, changeset(lifecycle, attrs))
    |> Ecto.Multi.insert(
      :audit,
      Audit.changeset(%Audit{
        professional_id: professional_id,
        action: action,
        resource_type: "patient",
        resource_id: patient_id,
        outcome: "success"
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{lifecycle: lifecycle}} ->
        {:ok, lifecycle}

      {:error, step, reason, _changes} ->
        Logger.warning("clinical_record lifecycle multi failed at #{step}")
        {:error, reason}
    end
  end

  defp deny_access(professional_id, patient_id) do
    case Audit.log_denied(professional_id, patient_id, "patient") do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning("clinical_record lifecycle log_denied failed: #{inspect(reason)}")
    end

    {:error, :unauthorized}
  end
end
