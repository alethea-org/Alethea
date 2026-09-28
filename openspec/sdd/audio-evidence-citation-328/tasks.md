# Tasks: Cite audio transcript evidence in the Workbench (#328)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~375 / PR2 ~275 / Total ~650 |
| 400-line budget risk | PR1: Medium (~94% of budget before any overrun) · PR2: Low |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (base: `main`) → PR2 (base: PR1 branch) |
| Delivery strategy | ask-on-risk (resolved: feature-branch-chain, #316/#317 precedent) |
| Chain strategy | feature-branch-chain |
| Branches | `feat/328-audio-evidence-citation` → `feat/328-audio-evidence-citation-pr2` |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

PR1 is inert on its own: the UI still rejects transcripts until PR2 adds the `citation_source_kind` clause. It is safe to land standalone.

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Domain: migration, schema, Retrieval, EvidenceSource, cite + markers, SourceRef, evidence_item | PR1 (base: `main`) | `mix test test/alethea/clinical_record/consultation_evidence_test.exs test/alethea/clinical_record/rag/retrieval_test.exs test/alethea/clinical_record/source_ref_test.exs test/alethea/clinical_record_test.exs` | N/A: there is no UI path until PR2 (`citation_source_kind` still rejects transcripts) | Delete any `session_transcript` evidence rows, run `mix ecto.rollback` one step, then revert the PR1 files |
| 2 | UI: AudioMarker, review.ex badge/marker/cite wiring, CSS, LiveView tests | PR2 (base: PR1 branch) | `mix test test/alethea_web/live/target_behavior_live/audio_marker_test.exs test/alethea_web/live/target_behavior_live/review_test.exs` | `mix phx.server` → Workbench with an indexed transcript: badge, marker, cite, timeline | Revert 5 files. PR1's columns stay dormant and safe |

---

## Phase 0 — Branch setup (mandatory; the local checkout is stale and predates #319/#320)

- [ ] 0.1 `git fetch origin`, then `git switch -c feat/328-audio-evidence-citation origin/main`. NEVER branch from the currently checked-out local branch.
- [ ] 0.2 Before editing, re-read every anchor in design.md's corrected line-number table on the new branch. Line numbers drift with each merge.

---

## PR1 — Domain (base: `main`, branch `feat/328-audio-evidence-citation`)

### Phase 1 — Migration + schema (R6, AD1, AD9)

- [ ] 1.1 RED `consultation_evidence_test.exs` changeset tests:
  - `session_transcript` is accepted when all three markers are present.
  - Any marker missing → invalid.
  - Speaker not in `SessionTranscriptContent.speakers()` → invalid.
  - Legacy kinds accept nil markers.
  - Write these table-driven (trim lever).
- [ ] 1.2 RED: inserting `source_kind = "clinician_observation"` raises on the CHECK. Also cover a legacy `clinical_note` row with NULL markers.
- [ ] 1.3 Run `mix ecto.gen.migration add_audio_markers_to_consultation_evidences`. Never hand-author the file.
- [ ] 1.4 GREEN migration body (`up`/`down`, AD1):
  - Drop and recreate `source_kind_must_be_valid` with `('clinical_note','message','session_transcript')`.
  - Add nullable `speaker :string`, `audio_start_seconds :float`, `audio_end_seconds :float`.
  - Add the `audio_markers_shape` CHECK.
  - `down` drops the columns and restores the two-kind CHECK.
  - Do NOT touch the `20260831213217` migration or its BEFORE UPDATE trigger.
- [ ] 1.5 GREEN `lib/alethea/clinical_record/consultation_evidence.ex`:
  - `@source_kinds` += `"session_transcript"`.
  - Add the 3 fields and cast them.
  - AD9 validation: all three are required when the kind is `session_transcript`, and the speaker must be in `SessionTranscriptContent.speakers()`.
- [ ] 1.6 Run `mix ecto.migrate` → `mix ecto.rollback` → `mix ecto.migrate` to prove reversibility.

### Phase 2 — Retrieval (R1)

- [ ] 2.1 RED `rag/retrieval_test.exs`:
  - A transcript chunk (`patient`, 860.0–910.0) → the result carries `speaker`, `audio_start_seconds`, `audio_end_seconds`.
  - A `clinical_note` chunk → all three are nil.
- [ ] 2.2 GREEN `lib/alethea/clinical_record/rag/retrieval.ex`:
  - Add the 3 fields to `@type result` (`:108-123`).
  - Read them from `chunk.*` in the result map (`:405-420`).
  - No branch on source kind (G1).

### Phase 3 — EvidenceSource (R7, AD4)

- [ ] 3.1 RED: fetching a `session_transcript` returns `kind: :session_transcript`, `occurred_at: recorded_at`, the parsed `:spans`, and `content` equal to the span texts joined with `"\n"`. A foreign-patient or missing id → `{:error, :not_found}`.
- [ ] 3.2 GREEN `lib/alethea/clinical_record/evidence_source.ex`:
  - Add `@type kind` `:session_transcript` and the `:spans` struct field (default nil).
  - Widen the guard (`:71-72`).
  - Add `fetch_owned("session_transcript", …)` via `Repo.get_by(SessionTranscript, id:, patient_id:)`.
  - `decrypt_source`: `PatientVault.decrypt(encrypted_spans, dek_for(v, keyring))` → `SessionTranscriptContent.parse/1`.

### Phase 4 — Cite with span hint (R4, R5, AD2, AD3, AD8)

- [ ] 4.1 RED `clinical_record_test.exs` `cite_evidence_source/4`, table-driven where possible:
  - A full span persists the span's speaker/start/end.
  - A trimmed excerpt inherits its span.
  - The hint selects between duplicate texts.
  - An excerpt outside the hinted span, or a hint that matches no span → `{:error, :excerpt_not_found}` and no row inserted. Markers are always taken from the matched span, never from the hint.
  - A long span that yields overlap chunks cites successfully (proposal risk).
- [ ] 4.2 GREEN `lib/alethea/clinical_record.ex`:
  - `cite_evidence_source/4` (`:761-782`) reads `Map.get(attrs, :span_hint)`.
  - Add `with … locate_excerpt(source, excerpt, hint)`.
  - Private `locate_excerpt/3` per AD2: filter the spans with `exact_excerpt(span.text, excerpt) == :ok`. If a hint is present, match `speaker` and `start*1.0`/`end*1.0`. Otherwise take the first span. Other kinds → `{:ok, %{}}`.
- [ ] 4.3 GREEN: `insert_consultation_evidence` (`:829-869`) takes a trailing `markers` map that it `Map.merge`s into the attrs. `add_consultation_evidence` passes `%{}`.
- [ ] 4.4 RED → GREEN: `evidence_item/3` (`:1428-1436`) adds `speaker`, `audio_start_seconds`, `audio_end_seconds`. Assert this via `review_timeline`.

### Phase 5 — SourceRef (R8, AD5)

- [ ] 5.1 RED `source_ref_test.exs`:
  - An existing transcript resolves to `%{kind: :session_transcript, occurred_at: recorded_at, reference: %{}}` without decrypting.
  - A deleted transcript → `:unavailable`.
- [ ] 5.2 GREEN `lib/alethea/clinical_record/source_ref.ex`:
  - `@known_kinds` += `session_transcript`.
  - Add `resolve_batch("session_transcript", refs)` → `resolve_batch_for(refs, SessionTranscript, &session_transcript_result/1)`.
  - `list/2` stays UNCHANGED (Q2).

### Phase 6 — PR1 verification

- [ ] 6.1 Run the Unit 1 focused command, then `mix compile --warnings-as-errors --force` and `mix format --check-formatted`.
- [ ] 6.2 **Budget check**: count authored lines with `git diff --stat origin/main`. If over 400, apply the trim levers first: table-drive 1.1/4.1, and merge the 3.1 fetch and not-found cases. Only then flag `size:exception` to the orchestrator. Never self-authorize it.
- [ ] 6.3 Confirm the diff has no `lib/alethea_web/**`, no CSS, and no `list/2` change.

---

## PR2 — UI (base: `feat/328-audio-evidence-citation`, branch `feat/328-audio-evidence-citation-pr2`)

- [ ] 7.0 `git switch -c feat/328-audio-evidence-citation-pr2 feat/328-audio-evidence-citation`. PR1 must itself be based on a fresh `origin/main`.

### Phase 7 — AudioMarker (R3, AD6, AD7)

- [ ] 7.1 RED `test/alethea_web/live/target_behavior_live/audio_marker_test.exs`, table-driven:
  - `format_range(0, 59.9)` → `"min 00:00 – 00:59"`.
  - `format_range(860, 910)` → `"min 14:20 – 15:10"`.
  - `format_range(4472, 4500)` → `"min 74:32 – 75:00"`.
  - The separator is an en dash.
- [ ] 7.2 GREEN `lib/alethea_web/live/target_behavior_live/audio_marker.ex`: pure `format_range/2`. `mmss` = `trunc` → `div`/`rem` 60, zero-padded to 2 digits, minutes unbounded.

### Phase 8 — review.ex wiring (R2, R4, R9, R10)

- [ ] 8.1 Extend `insert_rag_chunk!` (`review_test.exs:3970`) with an opts keyword for `speaker`, `audio_start_seconds`, `audio_end_seconds`.
- [ ] 8.2 RED LiveView tests:
  - Card and search result show the "Paciente"/"Terapeuta" badge and "min 14:20 – 15:10".
  - A non-transcript item shows no badge or marker.
  - `[+ Citar todo]`, `[Recortar]`, and `[+ Citar]` each persist the markers.
  - The timeline shows the badge and marker, and the source label is not "Fuente no disponible".
  - Forged `speaker`/time `phx-value-*` params are ignored, and the persisted markers equal the chunk's values.
  - Table-drive the three cite paths (trim lever).
- [ ] 8.3 GREEN in `lib/alethea_web/live/target_behavior_live/review.ex`: add `citation_source_kind("session_transcript"), do: {:ok, "session_transcript"}` at `:981-983`.
- [ ] 8.4 GREEN: add a private `citation_attrs(candidate, kind, excerpt)` that builds `span_hint` from the server-side assigns candidate. Use it in the handlers at `:359`, `:423`, and `:500`. Never read markers from client params.
- [ ] 8.5 GREEN: add the `source_label` clause for `%{kind: :session_transcript, occurred_at: t}` at `:1158-1168`. It renders `"Transcripción de sesión · #{format_datetime(t)}"`.
- [ ] 8.6 GREEN: add a `speaker_label/1` helper: `"patient"` → "Paciente", `"therapist"` → "Terapeuta".
- [ ] 8.7 GREEN: add the badge and marker spans after the `<time>` in both card headers (`:1720`, `:1860`). Add the same markup in the timeline `review-item__source` (`:1929`) when `item.kind == :consultation_evidence and item.speaker`.
- [ ] 8.8 VERIFY ONLY: `source_kind_label("session_transcript")` already exists at `:1207`. Add NO duplicate clause.
- [ ] 8.9 VERIFY ONLY (L4): the unsupported-kind test at `review_test.exs:2461` already uses `"clinician_observation"` (`:2480`). Make NO edit, and confirm it stays green.

### Phase 9 — CSS

- [ ] 9.1 In `priv/static/assets/css/editorial.css`:
  - Append `.badge--speaker` to the shared pill selector at `:2879-2880`.
  - Add `.badge--speaker-patient`, using the success tokens like `:2892`.
  - Add `.badge--speaker-therapist`, using canvas/body like `:2910`.
  - Add `.suggested-candidate-card__audio` with `font-variant-numeric: tabular-nums`.

### Phase 10 — PR2 verification

- [ ] 10.1 Run the Unit 2 focused command, then `mix compile --warnings-as-errors --force` and `mix format --check-formatted`.
- [ ] 10.2 **Budget check**: count lines with `git diff --stat feat/328-audio-evidence-citation`. The same trim-lever-first protocol applies (see 6.2).
- [ ] 10.3 Base check: the PR2 diff must not show PR1's files.
- [ ] 10.4 Resolve the design's open question with the orchestrator: a deleted transcript still renders "Fuente no disponible" while its snapshot badge and marker still show.
