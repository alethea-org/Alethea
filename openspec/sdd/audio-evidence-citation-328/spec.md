# Audio Evidence Citation Specification (#328)

## Purpose

Therapists can cite session-transcript excerpts in the Workbench, with the speaker and time anchor kept as provenance. New capability `audio-evidence-citation`; no existing spec is modified.

## Requirements

| # | Requirement | Strength |
|---|---|---|
| R1 | Retrieval results for `session_transcript` chunks carry `speaker`, `audio_start_seconds`, `audio_end_seconds` | MUST |
| R2 | Suggestion cards and search results show a speaker badge and a time marker for transcript items | MUST |
| R3 | Time marker format is `min mm:ss – mm:ss`, always `mm:ss` (L3) | MUST |
| R4 | Transcript items can be cited via `[+ Citar todo]`, `[Recortar]`, `[+ Citar]` | MUST |
| R5 | Cited evidence snapshots the chunk's own speaker/start/end (L1, L2) | MUST |
| R6 | `consultation_evidences` accepts `session_transcript` and stores nullable plaintext markers (Q1) | MUST |
| R7 | `EvidenceSource.fetch/4` supports `session_transcript` | MUST |
| R8 | `SourceRef` resolves `session_transcript` from metadata only (AC4) | MUST |
| R9 | Timeline evidence renders the snapshotted speaker and time marker | MUST |
| R10 | Kinds that are really unsupported stay non-citable (L4) | MUST |

### Requirement: Retrieval forwards audio markers (R1)

#### Scenario: Transcript chunk result
- GIVEN an indexed transcript chunk with speaker `patient`, 860.0–910.0 s
- WHEN `Retrieval.score_candidate/5` builds its result
- THEN the result includes `speaker`, `audio_start_seconds`, `audio_end_seconds` with those values

#### Scenario: Non-transcript chunk
- GIVEN a `clinical_note` chunk
- THEN those three fields are `nil`

### Requirement: Speaker badge and time marker (R2, R3)

#### Scenario: Patient speaker
- GIVEN a transcript suggestion or search result with speaker `patient`, 860–910 s
- WHEN the Workbench renders
- THEN it shows a "Paciente" speaker badge and "min 14:20 – 15:10"

#### Scenario: Therapist speaker
- GIVEN a transcript item with speaker `therapist`
- THEN it shows a "Terapeuta" speaker badge

#### Scenario: Past 60 minutes
- GIVEN start 4472 s, end 4500 s
- THEN the marker reads "min 74:32 – 75:00" (no hours field)

#### Scenario: Non-transcript item
- GIVEN a `clinical_note` or `patient_message` item
- THEN no speaker badge and no time marker render

### Requirement: Cite transcript chunks with markers (R4, R5)

Markers MUST come from the cited chunk row on the server. Client-supplied marker values MUST be ignored.

#### Scenario: Cite full chunk
- GIVEN a transcript suggestion card
- WHEN the therapist clicks `[+ Citar todo]` (or `[+ Citar]` on a search result)
- THEN a `consultation_evidences` row is created with `source_kind = "session_transcript"` and the chunk's speaker/start/end

#### Scenario: Cite trimmed excerpt
- GIVEN a transcript card
- WHEN the therapist confirms a `[Recortar]` excerpt
- THEN the row stores the trimmed excerpt plus the full chunk's speaker/start/end (span-level)

#### Scenario: Forged client markers
- GIVEN cite params that include speaker/time values
- THEN the persisted markers equal the chunk row's values

#### Scenario: Excerpt not in transcript
- GIVEN an excerpt that is not an exact substring of the cited span
- THEN the citation is rejected and no row is inserted

### Requirement: Evidence schema (R6)

#### Scenario: Transcript kind accepted
- GIVEN the migrated schema
- WHEN a row with `source_kind = "session_transcript"` is inserted
- THEN `@source_kinds` and the `source_kind_must_be_valid` CHECK accept it

#### Scenario: Legacy rows unaffected
- GIVEN existing `clinical_note`/`message` rows
- THEN `speaker`, `audio_start_seconds`, `audio_end_seconds` are `NULL` and the rows remain valid

#### Scenario: Unknown kind rejected
- WHEN a row with `source_kind = "clinician_observation"` is inserted
- THEN the CHECK rejects it

### Requirement: EvidenceSource transcript fetch (R7)

#### Scenario: Fetch transcript source
- GIVEN an accessible `SessionTranscript`
- WHEN `EvidenceSource.fetch/4` is called with `session_transcript`
- THEN it returns the decrypted content that contains the cited span, not an unsupported-kind error

#### Scenario: Missing transcript
- GIVEN an id that does not exist or belongs to another patient
- THEN fetch returns an error and nothing is cited

### Requirement: SourceRef metadata resolution (R8)

#### Scenario: Valid transcript evidence
- GIVEN a timeline evidence row sourced from an existing transcript
- WHEN `SourceRef.resolve_many/1` runs
- THEN it resolves using metadata only (e.g. `recorded_at`), without decrypting content
- AND the timeline never renders "Fuente no disponible" for it

### Requirement: Timeline markers (R9)

#### Scenario: Cited transcript evidence
- GIVEN a cited transcript evidence row with markers
- WHEN the timeline renders
- THEN it shows the speaker badge and "min mm:ss – mm:ss" beside the excerpt

### Requirement: Unsupported kinds regression (R10)

#### Scenario: Still-unsupported kind
- GIVEN a suggestion with source kind `clinician_observation`
- THEN only `[Descartar ✕]` renders (the existing test is repointed here from `session_transcript`)

## Out of Scope

Audio playback/seeking, word-level timing, diarization changes, and the manual "Citar evidencia" picker (`list_evidence_sources`, Q2).
