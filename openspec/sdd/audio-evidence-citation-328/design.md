# Design: Cite audio transcript evidence in the Workbench (#328)

**Inputs:** proposal.md (L1–L4, Q1–Q2 locked), exploration.md · **Base:** `origin/main`

## Grounding caveat — RESOLVED by orchestrator verification

This phase had no shell, so it could not `git show origin/main:…` directly and flagged G1/G2 plus all line numbers as unverified. The orchestrator re-verified everything below directly against `origin/main` after this phase completed:

- **G1 confirmed true**: `rag/chunk.ex` (origin/main) has `field :speaker, :string` (:67), `field :audio_start_seconds, :float` (:68), `field :audio_end_seconds, :float` (:69).
- **G2 confirmed true**: `Indexer.chunk_spans/1` (`indexer.ex:233-246`, origin/main) calls `Enum.flat_map` per span, chunking `span.text` independently via `chunk/1` and merging that same span's `speaker`/`start*1.0`/`end*1.0` onto every resulting piece — a chunk can never straddle two spans.
- **Domain-side line numbers (`clinical_record.ex`, `evidence_source.ex`, `source_ref.ex`, `retrieval.ex`, `consultation_evidence.ex`, the migration) all matched this design's citations almost exactly** — those files predate #319/#320 and are unchanged on `origin/main`.
- **`review.ex`/`review_test.exs` line numbers below were WRONG** and have been corrected in this doc. Cause: issue #319 ("Botón de generación de borrador E-O-R-C", PR #352) merged to `main` on 2026-09-25 and added ~120 lines near the top of `review.ex` (an `evidence_count`/`has_sufficient_evidence` gate plus the whole `generate_functional_analysis_draft` handler and its Mox test setup), shifting every subsequent line number. No functional conflict: `evidence_count` counts `items` by `kind == :consultation_evidence`, not by `source_kind`, so session-transcript-sourced evidence counts toward it exactly like any other kind — confirmed by reading `review.ex:56-59,881-889` on `origin/main`.

**Corrected real line numbers (origin/main, verified):**

| Anchor | Design's guess | Real |
|---|---|---|
| `citation_source_kind/1` clauses | `:860-862` | `:981-983` |
| `source_label/1` clauses | `:971-981` | `:1158-1168` |
| `source_kind_label/1` clauses | `:1020` | `:1205-1213` (already has a `"session_transcript"` clause at `:1207` from #320/#322 — do not duplicate) |
| `handle_event("cite_suggested_candidate", ...)` | `:356` | `:359` |
| `handle_event("confirm_trimmed_candidate", ...)` | `:420` | `:423` |
| `handle_event("cite_search_result", ...)` | `:497` | `:500` |
| Suggestion-card `<time class="suggested-candidate-card__time">` | `:1531-1536` | `:1720` |
| Search-result `<time class="suggested-candidate-card__time">` | `:1671-1676` | `:1860` |
| Timeline `<div class="review-item__source">` | `:1742-1744` | `:1929` |
| `editorial.css` shared pill selector (`.badge--affinity,\n.badge--source-kind,`) | `:2879-2881` | `:2879-2880` (unchanged) |
| `editorial.css` `.badge--affinity-high` / `-medium` / `-low` | `:2892-2896` / — | `:2892` / `:2898` / `:2904` |
| `editorial.css` `.badge--source-kind` | `:2910-2913` | `:2910` |
| `review_test.exs` "does not offer citation for suggestion source kinds unsupported..." (already uses `clinician_observation`, confirms L4 needs no edit) | `:2153-2184` | `:2461` (uses `"clinician_observation"` at `:2480`) |
| `review_test.exs defp insert_rag_chunk!` | `:3642` | `:3970` |

Apply must re-read each anchor at implementation time regardless (line numbers drift further with every merge) — this table exists so tasks.md doesn't inherit the stale numbers.

## Technical Approach

This is Fork A: speaker and times are snapshotted at cite time.

- The candidate map, which lives in server-side assigns and comes from the Retrieval → Chunk row, supplies a **span hint**.
- The domain re-decrypts the authoritative `SessionTranscript` and selects the span that matches the hint and contains the excerpt.
- The span's own speaker/start/end are persisted as plaintext columns (Q1).
- `SourceRef` resolves the transcript through `recorded_at` only.

## Architecture Decisions

| # | Decision | Rejected | Why |
|---|---|---|---|
| AD1 | New migration via `mix ecto.gen.migration add_audio_markers_to_consultation_evidences` with `up`/`down`: drop and recreate `source_kind_must_be_valid` with `('clinical_note','message','session_transcript')`; `add :speaker, :string`, `:audio_start_seconds, :float`, `:audio_end_seconds, :float` (nullable); new CHECK `audio_markers_shape` | Editing the #195 migration | The trigger (`20260831213217_create_consultation_evidences.exs:64-68`) is `BEFORE UPDATE … FOR EACH ROW`, so it fires only on row UPDATE DML. Nullable ADD COLUMN and ADD CONSTRAINT never UPDATE rows, so they are safe |
| AD2 | Markers come from the **authoritative decrypted span**. The chunk's values are used only as a hint to choose among spans | Persisting the chunk's values directly; re-fetching `Rag.Chunk` by `chunk_id` | Chunks are non-authoritative, and `replace_chunks` deletes and re-inserts rows with new ids (`chunk.ex:15-19`), so a stale `chunk_id` would fail the cite. The hint comes from `socket.assigns`, never from client params: the client sends only `phx-value-id` (`review.ex:356,497`) |
| AD3 | `cite_evidence_source/4` accepts an optional `:span_hint`. No new arity | Adding `/5`; passing markers as trusted attrs | This keeps a single validated cite path (`clinical_record.ex:761-782`) |
| AD4 | `EvidenceSource` struct gains `:spans` (nil for other kinds). `content` is the spans joined with `"\n"` | A separate transcript fetch module | Keeps the `fetch/4 → {:ok, t()}` contract (`evidence_source.ex:67-81`) |
| AD5 | `list/2` stays unchanged | Listing transcripts in the manual picker | Q2 puts the picker out of scope |
| AD6 | Separator `–` (en dash), text `"min 14:20 – 15:10"`, seconds floored, always `mm:ss` | The issue's ASCII `-` | L3 is locked with the en dash. Minutes are unbounded (`74:32`) |
| AD7 | The formatter is a new pure module `AletheaWeb.TargetBehaviorLive.AudioMarker` | A `defp` in review.ex | Easy to unit-test, and keeps the 2000-line LiveView from growing |
| AD8 | `[Recortar]` needs no special code | Separate trim marker logic | `review.ex:445` already requires `trimmed ⊂ candidate.content`, and the domain requires `excerpt ⊂ hinted span.text`. A trimmed excerpt therefore inherits its chunk's span (L2) |
| AD9 | Snapshot columns are validated on insert: when `source_kind == "session_transcript"` all three are required, and the speaker must be in `SessionTranscriptContent.speakers()` | No validation | The table is immutable, so bad rows are permanent |

## Data Flow

    Retrieval.score_candidate ─(speaker,start,end)─→ assigns candidate
       └ phx-click id ─→ handler builds %{source_kind,source_id,excerpt,span_hint}
          └→ cite_evidence_source → EvidenceSource.fetch("session_transcript")
               decrypt(CR DEK) → SessionTranscriptContent.parse → spans
             → locate_span(spans, excerpt, hint) → markers from span
             → insert_consultation_evidence(..., markers)
    review_timeline → evidence_item (+3 keys) + SourceRef(:session_transcript, recorded_at)

## Interfaces / Contracts

**Retrieval** (`retrieval.ex:108-123` @type, `:405-420` map): add `speaker: String.t() | nil`, `audio_start_seconds: float() | nil`, `audio_end_seconds: float() | nil`, and read them directly from `chunk.*`. No branch on source kind is needed because the columns are nil for other kinds (G1). The query selects the full struct (`:296-297`), and `suggest_evidence_candidates` passes results through untouched (`clinical_record.ex:514`).

**EvidenceSource** (`evidence_source.ex`):
- Widen the guard at `:71-72` to include `"session_transcript"`.
- Add `@type kind` `:session_transcript`.
- Add `fetch_owned("session_transcript", …)` using `Repo.get_by(SessionTranscript, id:, patient_id:)`.
- Add `decrypt_source`: `PatientVault.decrypt(encrypted_spans, dek_for(v, keyring))` → `SessionTranscriptContent.parse/1`, which returns `{:ok, %{spans: [%{start, end, speaker, text}]}} | {:error, :malformed}` (`session_transcript_content.ex:76-91`). Build the struct with `occurred_at: recorded_at` and `spans`.

**ClinicalRecord** (`clinical_record.ex`):

```elixir
with {:ok, source} <- EvidenceSource.fetch(kind, id, patient.id, keyring),
     {:ok, markers} <- locate_excerpt(source, excerpt, Map.get(attrs, :span_hint)) do
  insert_consultation_evidence(..., occurred_at, markers)
```

- `locate_excerpt(%{kind: :session_transcript, spans: spans}, excerpt, hint)`: keep the spans where `exact_excerpt(span.text, excerpt) == :ok`. If a hint is present, the span must also match `speaker` and `start*1.0`/`end*1.0`. Otherwise take the first span in order. No match returns `{:error, :excerpt_not_found}`.
- The other kinds keep the existing `exact_excerpt(source.content, excerpt)` and return `{:ok, %{}}`.
- `insert_consultation_evidence` (`:829-869`) gains a trailing `markers` map, which `Map.merge`s into the changeset attrs. `add_consultation_evidence` passes `%{}`.
- `evidence_item/3` (`:1428-1436`) adds `speaker`, `audio_start_seconds`, `audio_end_seconds`.

**SourceRef** (`source_ref.ex`):
- `@known_kinds` gains `session_transcript`.
- Add `resolve_batch("session_transcript", refs) -> resolve_batch_for(refs, SessionTranscript, &session_transcript_result/1)`, which returns `%{kind: :session_transcript, occurred_at: t.recorded_at, reference: %{}}`.
- No decryption. Only the `encrypted_spans` column is loaded, and it is never read.

**LiveView** (`review.ex`):
- Add `citation_source_kind("session_transcript"), do: {:ok, "session_transcript"}` at `:860-862`.
- Add a private `citation_attrs(candidate, kind, excerpt)` that builds `span_hint`. It is used by the handlers at `:367`, `:455` and `:508`.
- Add `source_label({:ok, %{kind: :session_transcript, occurred_at: t}})`, which renders `"Transcripción de sesión · #{format_datetime(t)}"` (`:971-981`).
- Add `speaker_label("patient")` → "Paciente" and `speaker_label("therapist")` → "Terapeuta".
- Inside each card `<header>`, after the `<time>` (`:1531-1536`, `:1671-1676`), add:
  - `<span :if={candidate.speaker} class={["badge","badge--speaker","badge--speaker-#{candidate.speaker}"]}>`
  - `<span :if={candidate.audio_start_seconds} class="suggested-candidate-card__audio">{AudioMarker.format_range(s, e)}</span>`
- In the timeline `review-item__source` (`:1742-1744`), render the same badge and marker when `item.kind == :consultation_evidence and item.speaker`.

**AudioMarker**: `format_range(start, stop) :: String.t()` returns `"min #{mmss(start)} – #{mmss(stop)}"`, where `mmss` = `trunc(s) |> div/rem 60`, zero-padded to 2 digits.

**CSS** (`editorial.css`):
- Append `.badge--speaker` to the shared pill selector at `:2879-2881`.
- Add `.badge--speaker-patient` (`--colors-success-*` tokens, like `:2892-2896`) and `.badge--speaker-therapist` (`--colors-canvas`/`--colors-body`, like `:2910-2913`).
- Add `.suggested-candidate-card__audio` using `font-variant-numeric: tabular-nums`.

## File Changes

| File | Action |
|---|---|
| `priv/repo/migrations/<ts>_add_audio_markers_to_consultation_evidences.exs` | Create |
| `lib/alethea/clinical_record/consultation_evidence.ex` | Modify: `@source_kinds`, fields, cast, AD9 validation |
| `lib/alethea/clinical_record/{evidence_source,source_ref}.ex`, `rag/retrieval.ex`, `clinical_record.ex` | Modify |
| `lib/alethea_web/live/target_behavior_live/audio_marker.ex` | Create |
| `lib/alethea_web/live/target_behavior_live/review.ex`, `priv/static/assets/css/editorial.css` | Modify |

## Testing Strategy (Strict TDD)

| Layer | Tests |
|---|---|
| Unit | `AudioMarker` (0, 59.9, 860→"14:20", 4472→"74:32"); `ConsultationEvidence` AD9 changeset |
| Domain | `Retrieval` forwards the markers, and returns nil for notes; `EvidenceSource` fetches a transcript, rejects a foreign patient with `:not_found`; `cite_evidence_source` with a full span, a trimmed excerpt, the hint selecting between duplicate texts, an excerpt outside the hinted span → `:excerpt_not_found`, and a long span that produces overlap chunks (proposal risk); `SourceRef` resolves a transcript / returns `:unavailable` when deleted; migration rollback |
| LiveView | Extend `insert_rag_chunk!` (`review_test.exs:3642`) with an opts keyword for speaker/audio. Cover the card badge and marker, `[+ Citar todo]`, `[Recortar]`, `[+ Citar]`, and the timeline marker plus a source label that is not "Fuente no disponible" |

**L4:** `review_test.exs:2153-2184` already uses `"clinician_observation"` (`:2172`), which stays unsupported after this change. No edit is needed unless main differs (apply gate).

## Threat Matrix

N/A: no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

Additive columns. The `down` step drops the columns and restores the two-kind CHECK. It fails if any `session_transcript` rows exist, so those rows must be deleted first (proposal rollback).

## Review Workload Forecast

| Slice | Prod | Tests | Total |
|---|---|---|---|
| PR1 domain (migration, schema, EvidenceSource, cite, SourceRef, Retrieval, evidence_item) | ~175 | ~200 | ~375 |
| PR2 UI (review.ex, AudioMarker, CSS, review_test) | ~115 | ~160 | ~275 |

The combined ~650 lines put the **400-line budget risk at High**, so **chained PRs are recommended**, following the #317 pattern. PR1 is inert on its own: the UI still rejects transcripts until PR2 adds the `citation_source_kind` clause.

## Open Questions

- [ ] A deleted transcript still renders "Fuente no disponible" (the same as for other kinds). The snapshot badge and marker still show. This is acceptable under AC4 only if "never placeholder" applies to live sources.
