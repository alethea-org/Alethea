defmodule Alethea.ClinicalRecord.SourceRef do
  @moduledoc """
  Read-only, no-FK adapter resolving `ConsultationEvidence.source_kind` +
  `source_id` into display metadata for the review timeline
  (sdd/alethea/issue-195-clinical-review-workbench, GitHub #195, design A2/A3
  "SourceRef adapter" section).

  **Metadata only** — never returns ciphertext or plaintext excerpt text
  (the excerpt itself is already stored, encrypted, on the citing
  `ConsultationEvidence` row per design A3). This module only tells the
  timeline what the cited source *is* — its kind, its own timestamp, and a
  small display reference — not what it *says*.

  `alias Alethea.Clinical, as: Journaling` per the moduledoc collision rule
  (`Alethea.ClinicalRecord` must not depend on `Alethea.Clinical` beyond
  this explicit, aliased, read-only lookup — no `belongs_to`, no FK).

  Degrades gracefully to `:unavailable` on:
    * an unknown `source_kind` (not `"clinical_note"` or `"message"`)
    * a well-formed id with no matching row (deleted/erased source)
    * a malformed id (not a valid UUID string)

  so a citation to a source that has since been deleted or cryptographically
  erased in its own scope still renders on the timeline from its stored
  excerpt (design A3) instead of crashing.

  `resolve_many/1` batches lookups per kind with `id in ^ids` queries — two
  queries total regardless of list size, no N+1.
  """
  import Ecto.Query

  alias Alethea.Clinical, as: Journaling
  alias Alethea.ClinicalRecord.ClinicalNote
  alias Alethea.Repo

  @known_kinds ~w(clinical_note message)

  @type ref :: {String.t(), Ecto.UUID.t()}
  @type result ::
          {:ok, %{kind: :clinical_note | :message, occurred_at: DateTime.t(), reference: map()}}
          | :unavailable

  @doc """
  Resolves a single `{source_kind, source_id}` pair. See moduledoc for the
  `:unavailable` degradation cases.
  """
  @spec resolve(String.t(), Ecto.UUID.t()) :: result()
  def resolve(source_kind, source_id) do
    [{source_kind, source_id}]
    |> resolve_many()
    |> Map.fetch!({source_kind, source_id})
  end

  @doc """
  Batch-resolves a list of `{source_kind, source_id}` refs, grouped and
  queried per kind (no N+1). Returns a map keyed by the original ref tuple.
  """
  @spec resolve_many([ref()]) :: %{ref() => result()}
  def resolve_many(refs) when is_list(refs) do
    refs
    |> Enum.uniq()
    |> Enum.group_by(fn {kind, _id} -> kind end)
    |> Enum.flat_map(fn {kind, kind_refs} -> resolve_batch(kind, kind_refs) end)
    |> Map.new()
  end

  defp resolve_batch(kind, refs) when kind not in @known_kinds do
    Enum.map(refs, &{&1, :unavailable})
  end

  defp resolve_batch("clinical_note", refs) do
    resolve_batch_for(refs, ClinicalNote, &clinical_note_result/1)
  end

  defp resolve_batch("message", refs) do
    resolve_batch_for(refs, Journaling.Message, &message_result/1)
  end

  defp resolve_batch_for(refs, schema, result_fn) do
    {valid_refs, invalid_refs} =
      Enum.split_with(refs, fn {_kind, id} -> match?({:ok, _}, Ecto.UUID.cast(id)) end)

    valid_ids = Enum.map(valid_refs, fn {_kind, id} -> id end)

    rows_by_id =
      schema
      |> where([r], r.id in ^valid_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    found =
      Enum.map(valid_refs, fn {_kind, id} = ref ->
        case Map.fetch(rows_by_id, id) do
          {:ok, row} -> {ref, {:ok, result_fn.(row)}}
          :error -> {ref, :unavailable}
        end
      end)

    found ++ Enum.map(invalid_refs, &{&1, :unavailable})
  end

  defp clinical_note_result(note) do
    %{kind: :clinical_note, occurred_at: note.inserted_at, reference: %{}}
  end

  defp message_result(message) do
    %{
      kind: :message,
      occurred_at: message.timestamp,
      reference: %{
        behavior_type: message.behavior_type,
        direction: message.direction,
        timestamp: message.timestamp
      }
    }
  end
end
