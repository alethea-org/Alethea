# Proposal: Cite audio transcript evidence in the Workbench (#328)

**Status:** decided — Q1/Q2 locked by the user (both recommended defaults) · **Parent:** #314 · **Blocked by:** #320, #321 (closed) · **Base:** `origin/main`

## Intent

Session transcripts are indexed, filterable, and labelled in the Workbench (#320/#322/#325), but therapists cannot cite them. Cards show only `[Descartar ✕]`, and any transcript evidence would resolve as "Fuente no disponible". Therapists need to see who spoke and when, and keep that anchor on the timeline.

## Scope

### In Scope
- Speaker badge (Paciente / Terapeuta) and time marker ("min 14:20 – 15:10") on suggestion cards and search results.
- Cite transcript chunks via `[+ Citar todo]`, `[Recortar]`, and `[+ Citar]`.
- Snapshot speaker and start/end seconds onto `consultation_evidences`, and render them on timeline evidence.
- `SourceRef` / `EvidenceSource` resolve `session_transcript` using metadata only, with no placeholder.
- `Retrieval` result map forwards `speaker`, `audio_start_seconds`, `audio_end_seconds`.

### Out of Scope
- Audio playback or seeking, sub-span (word-level) timing, diarization changes.
- Manual "Citar evidencia" picker (`list_evidence_sources`), pending Q2.

## Capabilities

### New Capabilities
- `audio-evidence-citation`: citing session-transcript excerpts with speaker/time provenance, plus source resolution.

### Modified Capabilities
- None (`openspec/specs/` absent).

## Approach

Exploration **Fork A**:
- Migration: extend the `source_kind_must_be_valid` CHECK and `@source_kinds` with `session_transcript`, and add nullable `speaker`, `audio_start_seconds`, `audio_end_seconds`. ADD COLUMN is safe under the BEFORE UPDATE trigger.
- Markers are derived **server-side** from the cited chunk row (`chunk_id`), never from client params.
- The LiveView stays thin. It gets a `citation_source_kind` clause, a speaker badge that copies the `badge--source-kind` precedent, and a pure formatter.

Rejected: render-time decryption in `SourceRef` (breaks its metadata-only contract, ambiguous across spans); markers inside the encrypted excerpt (corrupts exact-excerpt semantics).

## Locked decisions

| # | Decision | Basis |
|---|---|---|
| L1 | Snapshot at cite time (Fork A) | Excerpt-copy precedent; survives source deletion |
| L2 | Markers come from the chunk row, span-level. A trimmed excerpt inherits its chunk's span range | `Indexer.chunk_spans/1` never crosses spans (exploration, confirmed on main; re-verify in design) |
| L3 | Format is always `mm:ss`, including 60+ min ("74:32"), with the prefix "min a – b" | Matches the issue's example, compact, monotonic |
| L4 | Keep the "unsupported kind" test on a still-unsupported kind (`clinician_observation`) | Prevents a false negative |

## Decisions Q1-Q2 (locked by user)

Both confirmed with the recommended default.

| # | Decision | Chosen |
|---|---|---|
| Q1 | Snapshot columns storage | **Plaintext** — mirrors #317 D1 / #320 D3 precedent; weak PII; the excerpt text itself stays encrypted regardless |
| Q2 | Manual "Citar evidencia" picker scope | **Out of scope for #328** — the ACs name only suggestion cards, search results, and timeline evidence, not a manual browse-and-cite flow |

## Affected Areas

| Area | Impact |
|---|---|
| `lib/alethea_web/live/target_behavior_live/review.ex` | Modified |
| `lib/alethea/clinical_record/rag/retrieval.ex` | Modified |
| `lib/alethea/clinical_record/{evidence_source,source_ref,consultation_evidence}.ex`, `clinical_record.ex` | Modified |
| `priv/repo/migrations/<ts>_add_audio_markers_to_consultation_evidences.exs` | New |
| `priv/static/assets/css/editorial.css` | Modified |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Local branch lacks #320 | High | Branch from `origin/main` |
| Oversized-span chunk text is not an exact substring, so `exact_excerpt` fails | Med | Test the `[+ Citar todo]` path on long spans |
| CLAUDE.md "audio metadata" deviation | Med | Q1, documented |

## Rollback Plan

Revert the commit plus `mix ecto.rollback` one step. Before rolling back, delete `session_transcript` evidence rows (the CHECK would otherwise fail) or keep the widened CHECK.

## Success Criteria

- [ ] Transcript cards and results show the speaker badge and "min mm:ss – mm:ss".
- [ ] Citing (full or trimmed) persists the markers, and the timeline renders them.
- [ ] Transcript evidence never renders "Fuente no disponible".
- [ ] `mix precommit` passes.
