# Exploration — audio-evidence-citation-328 (#328)

**Status:** exploration complete
**Issue:** #328 — Cita de evidencia desde transcripciones de audio en Workbench
**Parent:** #314 — Spec: Semantic evidence discovery, E-O-R-C auto-drafting, and session audio transcriptions
**Blocked by:** #320 (RAG ingestion of transcripts), #321 (async Top 5 suggestions) — both CLOSED and merged to `main`.

## Branch caveat

The exploration was run from `feat/317-session-transcript-pr2`, which does **not** contain #320. `indexer.ex`/`chunk.ex` on that branch have no session_transcript code. Commit `7fad7b7` (#320) and its landing PR are on `origin/main` — confirmed by fetching raw files from GitHub directly. Implementation must branch from `origin/main`. Line numbers below are from the local checkout except where marked "same on main" or "confirmed on main."

## Executive summary

For #328 the workbench already labels, filters, and scores session-transcript chunks (source-type filtering and labelling from #320/#322/#325 already work). What's missing is citing them, resolving them as a source, and carrying the time/speaker metadata through. Recommendation: at citation time, derive speaker and time markers on the server and store them as a snapshot in new nullable `consultation_evidences` columns, then extend `SourceRef`/`EvidenceSource` with a `session_transcript` clause.

## Current state (file:line)

### 1. The workbench is one file

`lib/alethea_web/live/target_behavior_live/review.ex` (2004 lines) has an inline `~H` render starting at line 1037. There is no `.heex` file and no component module.

- **Suggestion cards** (lines 1479–1615): `<.async_result assign={@suggested_candidates}>`. Each `article.suggested-candidate-card` has a header with `badge badge--affinity badge--affinity-#{tier}`, `badge badge--source-kind badge--source-#{source_resource_type}`, `<time class="suggested-candidate-card__time">` showing `source_occurred_at`. Actions: `[+ Citar todo]`, `[Recortar]` (inline trim form), `[Descartar ✕]`.
- **Search results** (lines 1617–1703): same card markup, id `evidence-search-result-#{chunk_id}`, with `[+ Citar]` and a "✓ Citado" badge.
- **Timeline evidence** (lines 1713–1804): stream `@streams.timeline`. Evidence items show `item.text` (the decrypted excerpt) plus `source_label(item.source)` at line 1743.

### 2. Badge precedent

- Markup: `badge badge--source-kind badge--source-#{type}` and `badge--affinity-#{tier}` (`review.ex:1517-1530`).
- CSS: `priv/static/assets/css/editorial.css:2879-2919` — pill base shared by `.badge--affinity, .badge--source-kind, .badge--cited`, plus per-tier color rules.
- A new `badge--speaker badge--speaker-patient|therapist` would copy this directly.

### 3. Source-type branching already exists

- `@search_source_filters` includes `%{id: "sessions", label: "Sesiones"}` (`review.ex:38-43`).
- `Retrieval.filter_by_source(:sessions)` maps to `["session_transcript", "session_transcripts", "session", "clinical_session"]` (`retrieval.ex:315-326`).
- `source_kind_label("session_transcript")` returns "Transcripción de sesión" (`review.ex:1020`).
- So filtering and labelling already work. Citation and resolution do not.

### 4. No time formatter exists

Nothing in `lib/` formats seconds as mm:ss. The only related code is `notification_center.ex:246`, which does relative "Xm" formatting. This part is greenfield UI logic.

### 5. How citing works today

- `cite_suggested_candidate` (356), `confirm_trimmed_candidate` (420), and `cite_search_result` (497) all call `ClinicalRecord.cite_evidence_source/4` with only `%{source_kind, source_id, excerpt}`.
- `citation_source_kind/1` (860-862) maps only `"clinical_note"` and `"patient_message"`. `"session_transcript"` returns `{:error, :unsupported_source}`.
- As a result `citable_candidate?/1` is false for transcript chunks, and their cards show only `[Descartar ✕]`. Test `review_test.exs:2153` locks in this "no cite for unsupported kinds" behaviour.
- In the domain, `cite_evidence_source` (`clinical_record.ex:761`) calls `EvidenceSource.fetch/4`, which rejects any kind other than clinical_note/message (`evidence_source.ex:71-73`). It then runs `exact_excerpt` and inserts `ConsultationEvidence` with only `source_kind`, `source_id`, the encrypted excerpt, and `occurred_at`.
- **No time or speaker field exists on `ConsultationEvidence`.** Its `@source_kinds ~w(clinical_note message)`, and the DB CHECK `source_kind_must_be_valid` (`priv/repo/migrations/20260831213217_create_consultation_evidences.exs:51-52`) enforces the same set. The table also has a `BEFORE UPDATE` immutability trigger.
- AC3 therefore needs a migration (extend the CHECK, add columns) plus a domain change.

### 6. Source resolution — the AC4 crux

- `review_timeline/3` (`clinical_record.ex:1383`) resolves sources with `SourceRef.resolve_many/1`.
- `SourceRef` (`lib/alethea/clinical_record/source_ref.ex`) has `@known_kinds ~w(clinical_note message)`. Any other kind becomes `:unavailable`, and `source_label/1` (`review.ex:971-981`) renders that as "Fuente no disponible". **This is the "placeholder degradation" AC4 refers to.**
- The excerpt text goes through `decrypt_or_placeholder` (`clinical_record.ex:1471`). It only falls back to "[Error al descifrar]" when decryption fails — unrelated to source kind.
- `evidence_item/3` (1428) returns `%{id, kind, occurred_at, text, source}` with no speaker or time fields.

### 7. Chunk shape on main (#320) — confirmed on main

- `Rag.Chunk` adds plaintext `speaker :string`, `audio_start_seconds :float`, `audio_end_seconds :float`. The moduledoc says only transcript chunks set them ("speaker is plaintext by design (D3)").
- `Indexer.chunk_spans/1` chunks each span on its own (a chunk never crosses spans) and copies `speaker`, `start*1.0`, `end*1.0` onto every piece.
- `source_resource_type = "session_transcript"`, `source_resource_id` is the `SessionTranscript` id, `source_occurred_at = transcript.recorded_at`. Re-resolving from a chunk back to its transcript is possible.
- **However, `Retrieval.score_candidate/5` (`retrieval.ex:405-420`, same on main) does not include speaker or audio fields in its result map.** The LiveView never receives them.

### 8. Tests

`test/alethea_web/live/target_behavior_live/review_test.exs`:
- Pattern: `live/2` → `render_async(view)`, then selectors like `element(view, "#suggested-candidates-list article:nth-child(n) .badge--source-kind") |> render() =~ ...`, plus `has_element?` with `phx-click` selectors and `render_click`.
- `insert_rag_chunk!/7` helper (3642) builds a fixed attrs map through `Indexer.replace_chunks/2`. Needs opts for speaker and audio fields.
- `insert_evidence!` (3559) uses `ConsultationEvidence.changeset` directly.
- Prior-art tests present for #321 (1964), #324 (2222), #322 (2418), #325 (2600), #326 (2830), #327 (3089) — confirms those issues are landed, not net-new design surfaces.

## Affected areas

- `lib/alethea_web/live/target_behavior_live/review.ex`: `citation_source_kind` clause, speaker badge and time marker on both card types and on timeline evidence, `source_label` clause for session_transcript, mm:ss formatter.
- `lib/alethea/clinical_record/rag/retrieval.ex`: add `speaker`, `audio_start_seconds`, `audio_end_seconds` to the result map and `@type result`.
- `lib/alethea/clinical_record/evidence_source.ex`: `session_transcript` fetch/decrypt clause (parse spans via `SessionTranscriptContent`).
- `lib/alethea/clinical_record.ex`: `cite_evidence_source` derives the marker from the authoritative span; `insert_consultation_evidence` and `evidence_item` carry the new fields.
- `lib/alethea/clinical_record/consultation_evidence.ex` plus a new migration: extend `@source_kinds` and the CHECK constraint; add nullable speaker and start/end columns.
- `lib/alethea/clinical_record/source_ref.ex`: `session_transcript` batch using `SessionTranscript.recorded_at` (metadata only).
- `priv/static/assets/css/editorial.css`: speaker badge rules.
- Tests: `review_test.exs` (extend `insert_rag_chunk!`), plus retrieval, evidence_source, and source_ref tests.

## Approaches compared — keeping time markers on cited evidence (AC3)

| # | Approach | Pros | Cons | Effort |
|---|---|---|---|---|
| A | Snapshot columns on `consultation_evidences` (speaker, audio_start/end_seconds, nullable); values derived on the server from the decrypted span at cite time | Matches the codebase's "excerpt copied at citation" precedent; timeline survives source deletion; no extra decryption on render | Migration on an immutable table (ADD COLUMN is safe — the trigger only fires on row UPDATE); CHECK constraint change | Medium |
| B | Resolve markers at render time in `SourceRef` by decrypting the transcript and locating the excerpt | No schema change | Breaks `SourceRef`'s "metadata only, never plaintext" contract; lost when the source is deleted; ambiguous when the excerpt appears in more than one span | Medium |
| C | Encode markers into the encrypted excerpt text | No schema change | Corrupts the exact-excerpt meaning; hacky | Low (rejected) |

## Recommendation

**Approach A.**
- Pass the chunk's span hint (`audio_start_seconds`) or match the excerpt against spans inside `cite_evidence_source`. Markers are span-level, so a trimmed excerpt inherits its span's start and end.
- Keep the LiveView thin: add a `citation_source_kind("session_transcript")` clause and render badges and markers from the result/timeline maps.
- Add a pure formatter (seconds → "min mm:ss – mm:ss") that can be unit-tested.

## Risks

1. **Wrong branch.** The working tree used for exploration lacks #320 — implementation must start from `origin/main`.
2. **Plaintext vs encrypted speaker/time on `consultation_evidences`.** Storing as plaintext follows the chunk's own D3 precedent from #320, but departs from CLAUDE.md's "audio metadata encrypted" mandate (same tension already accepted-and-documented for #317's `audio_duration_seconds`). Needs an explicit decision.
3. **Exact-substring check can fail.** For oversized spans, `Indexer.chunk/1` trims paragraphs and re-joins them with " " plus overlap. A chunk's content may then not be an exact substring of the span text, so `[+ Citar todo]` could fail `exact_excerpt` — this already affects long notes, not new to this issue, but worth confirming doesn't get worse for transcripts.
4. **Excerpt appears in multiple spans.** Marker attribution is ambiguous without a span hint carried from the chunk/result all the way to the citation call.
5. **Scope ambiguity.** Should the manual "Citar evidencia" flow (`list_evidence_sources`) list transcripts too? The ACs don't require it.
6. **mm:ss vs h:mm:ss.** Sessions of 60+ minutes need a formatting decision.
7. **Existing test must stay valid.** `review_test.exs:2153` ("unsupported kinds are not citable") must keep using a kind that's still actually unsupported (e.g. `clinician_observation`) once `session_transcript` becomes supported.

## Key learnings

1. `citation_source_kind/1` in `review.ex` maps only `clinical_note` and `patient_message`, so session-transcript cards currently cannot be cited at all.
2. `SourceRef` only knows the `clinical_note` and `message` kinds, so any session_transcript evidence renders as "Fuente no disponible".
3. The `consultation_evidences` table has a DB CHECK constraint restricting `source_kind` to `clinical_note` and `message`, so citing transcripts requires a migration.
4. On `main`, `Rag.Chunk` stores plaintext speaker and audio start/end seconds per span, but `Retrieval.score_candidate/5` drops them from its result map before the LiveView ever sees them.
5. The codebase has no existing mm:ss time formatter, so audio time-marker formatting is new UI logic.
