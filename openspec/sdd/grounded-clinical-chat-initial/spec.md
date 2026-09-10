# Spec — grounded-clinical-chat-initial

**Change:** grounded-clinical-chat-initial (GitHub #223; slices #226 → #227 → #232 → #234)
**Authority:** ADR-010 (6 domain decisions), spec issue #221, `openspec/UBIQUITOUS_LANGUAGE.md`.
**Fixed by proposal (not re-decided here):** D1 (hypothesis mode deferred), D2 (`:local`-only synthesis), D3 (sufficiency threshold in the contract, config-exposed, 0.35), D4 (`:stale` carries `pending` count), D5 (ClinicalSearch hard cutover), and the in/out-of-scope lists.
**Test runner:** `mix test` (strict TDD).

## New Capability: `grounded-clinical-consultation`

### Purpose

An authorized psychologist asks a natural-language clinical question about one of their patients and receives an answer that visibly separates **Síntesis basada en evidencia** from **Fuentes**, where every source is a verbatim excerpt from that patient's indexed history. The chat blocks rather than answers when the record does not support a claim or when the patient's index is not fresh. Nothing about the conversation is persisted, and the chat is the single primary surface for navigating the clinical record.

### Requirements

#### Requirement: Typed Consultation Outcome Contract (#226)

`Alethea.ClinicalRecord.Consultation.answer/4` MUST return a single typed result whose `outcome` is exactly one of `:synthesis | :no_evidence | :stale | :provider_failure`. No other outcome value MAY exist. A blocking outcome (`:no_evidence`, `:stale`, `:provider_failure`) MUST NOT carry synthesis prose or sources.

##### Scenario: Synthesis outcome carries answer and server-derived sources
- GIVEN an authorized professional, a fresh patient index, and retrieval returning excerpts at or above the sufficiency threshold
- WHEN `answer/4` is called
- THEN `outcome` is `:synthesis` with non-empty synthesis text AND a non-empty `sources` list derived from the retrieval envelope

##### Scenario: No-evidence outcome blocks without fallback
- GIVEN retrieval returns no excerpt at or above the sufficiency threshold
- WHEN `answer/4` is called
- THEN `outcome` is `:no_evidence`, synthesis is absent, `sources` is empty, AND no general-knowledge answer is produced

##### Scenario: Stale outcome blocks and asks for retry
- GIVEN patient freshness `stale? == true` with N pending indexing jobs
- WHEN `answer/4` is called
- THEN `outcome` is `:stale` carrying `pending: N`, no synthesis is attempted, AND the result signals that the professional should retry once indexing completes

##### Scenario: Provider-failure outcome is a safe state
- GIVEN the synthesis chain raises or returns an error
- WHEN `answer/4` is called
- THEN `outcome` is `:provider_failure` with no partial synthesis text and no sources leaked

#### Requirement: Server-Derived Source Provenance (#226)

Every `Consultation.Source` MUST expose the exact evidence excerpt, its source kind, its date, and a stable reference. Sources MUST be built server-side from the `Rag.Retrieval.search/4` envelope. The synthesis LLM MUST return prose only and MUST have no channel to add, remove, or fabricate a source.

##### Scenario: Source exposes excerpt, kind, date, reference
- GIVEN a `:synthesis` result
- WHEN a source is inspected
- THEN it has a verbatim excerpt, a source kind, a date, and a stable reference identifier

##### Scenario: LLM cannot inject or fabricate a source
- GIVEN a chain fake whose prose names a citation absent from the retrieval envelope
- WHEN `answer/4` runs
- THEN the returned `sources` equal exactly those derived from the envelope AND contain nothing invented by the model

#### Requirement: Controlled Fakes for Every Outcome (#226)

`Consultation.Fake` and the chain mock MUST be able to produce each of the four outcomes deterministically for tests, without real retrieval or a real LLM.

##### Scenario: Each outcome is reproducible via the fake
- GIVEN the fake configured for `:synthesis`, `:no_evidence`, `:stale`, and `:provider_failure` in turn
- WHEN `answer/4` is called
- THEN it returns that exact outcome with contract-valid data

#### Requirement: Clinical Sources Are Read-Only (#226, #232)

A consultation MUST NOT create, update, delete, or otherwise mutate any indexed chunk, clinical record, freshness state, or outbox job.

##### Scenario: Any turn leaves clinical state untouched
- GIVEN any consultation turn (synthesis or any block)
- WHEN it completes
- THEN the patient's chunks, clinical records, and outbox jobs are identical to before the turn

#### Requirement: Local-Only Synthesis, No External Leak (#226, D2)

Consultation synthesis MUST run through a provider whose `supported_providers/0` is `[:local]` only, making a `:cloud` configuration for this chain structurally impossible. Decrypted clinical excerpts MUST NOT be transmitted to any external or cloud provider.

##### Scenario: Cloud provider is rejected for this chain
- GIVEN any provider configuration for the clinical consultation chain
- WHEN the chain resolves its provider
- THEN only `:local` is accepted and a `:cloud` selection is rejected

#### Requirement: Authorized Per-Patient Consultation Surface (#227)

`AletheaWeb.ConsultationLive` MUST run inside the authenticated-professional live session and MUST authorize the acting professional against the patient on mount and on every turn. An unauthorized professional MUST be redirected away and MUST see no consultation content.

##### Scenario: Unauthorized professional is redirected
- GIVEN professional B opens the consultation for professional A's patient
- WHEN the LiveView mounts
- THEN B is redirected away AND no patient data is rendered

##### Scenario: Treating professional reaches the idle state
- GIVEN the treating professional
- WHEN the LiveView mounts
- THEN the idle state renders

#### Requirement: All Safe Visible States (#227)

The LiveView MUST render each of six distinct states — idle, retrieving, synthesis, indexed-no-evidence, stale-pending (showing the `pending` count), provider-error — and MUST consume `Consultation.Fake` only in this slice (no real retrieval).

##### Scenario: Idle state
- GIVEN a freshly mounted conversation
- WHEN nothing has been asked
- THEN the idle state renders with no answer and no error

##### Scenario: Retrieving state
- GIVEN a submitted question with the turn in flight
- WHEN the fake has not yet resolved
- THEN a retrieving/in-progress state renders

##### Scenario: Synthesis state
- GIVEN the fake yields `:synthesis`
- WHEN the turn renders
- THEN synthesis text and a sources list are shown

##### Scenario: Indexed-no-evidence state
- GIVEN the fake yields `:no_evidence`
- WHEN the turn renders
- THEN a "record does not support an answer" state renders with no synthesized answer

##### Scenario: Stale-pending state shows the count
- GIVEN the fake yields `:stale` with `pending: N`
- WHEN the turn renders
- THEN a blocked state renders showing N pending jobs and a retry prompt

##### Scenario: Provider-error state
- GIVEN the fake yields `:provider_failure`
- WHEN the turn renders
- THEN a safe error state renders with no partial synthesis

#### Requirement: No Persistence of Conversation State (#227, ADR-010 decision 6)

Consultation conversation state MUST live only in LiveView socket assigns. It MUST NOT survive remount, navigation away and back, logout/login, or starting a new conversation. No ETS (`ConversationMemory`), database row, browser storage, or access/audit metadata MAY be written.

##### Scenario: State does not survive remount
- GIVEN a conversation with prior turns
- WHEN the LiveView remounts
- THEN the conversation is empty

##### Scenario: State does not survive navigation
- GIVEN a conversation with prior turns
- WHEN the professional navigates away and returns
- THEN the conversation is empty

##### Scenario: State does not survive logout
- GIVEN a conversation with prior turns
- WHEN the professional logs out and logs back in
- THEN no prior turn is recoverable

##### Scenario: New conversation discards prior context
- GIVEN a conversation with prior turns
- WHEN "new conversation" is triggered
- THEN prior follow-up context is discarded

##### Scenario: No conversation content is written anywhere
- GIVEN any number of completed turns
- WHEN persistence stores are inspected
- THEN no ETS, database, browser-storage, or audit/access record of conversation content exists

#### Requirement: Authorize Before Retrieve (#232)

`Consultation.Live` MUST authorize via `Accounts.get_patient_for_professional/2` and pass before any retrieval, embedding, or synthesis work. A failed authorization MUST yield an unauthorized error and MUST NOT trigger retrieval.

##### Scenario: Failed authorization never reaches retrieval
- GIVEN an unauthorized professional/patient pair
- WHEN `answer/4` runs
- THEN authorization fails first AND `Rag.Retrieval.search/4` is never invoked

#### Requirement: Fresh Full-History Retrieval Every Turn (#232, ADR-010 decision 1)

Every turn MUST perform a fresh `Rag.Retrieval.search/4` over the patient's complete indexed history. Conversation history MAY only resolve follow-up phrasing into a standalone query; it MUST NOT be passed as or counted as evidence.

##### Scenario: Retrieval re-runs on every turn
- GIVEN a second turn in the same conversation
- WHEN it runs
- THEN a new retrieval executes over the full indexed history, not a cached or narrowed prior result

##### Scenario: Conversation history is never evidence
- GIVEN a follow-up phrased relative to a prior turn ("and about that?")
- WHEN it runs
- THEN prior turn text is used only to form the query AND no source is derived from conversation content

#### Requirement: Freshness Is a Hard Gate (#232, ADR-010 decision 5, D4)

When `freshness.stale? == true` the outcome MUST be `:stale` with the pending count and no synthesis attempt.

##### Scenario: Pending indexing blocks the answer
- GIVEN one or more pending `ClinicalRecordOutboxWorker` jobs for the patient
- WHEN `answer/4` runs
- THEN `outcome` is `:stale` with `pending > 0` AND the synthesis chain is not called

#### Requirement: Evidence Sufficiency Threshold (#232, D3)

The evidence-sufficiency threshold MUST live in the `Alethea.ClinicalRecord.Consultation` contract, be exposed via application config, and default to `0.35`. Empty retrieval results, or results all scoring below the threshold, MUST yield `:no_evidence`.

##### Scenario: Empty results yield no-evidence
- GIVEN retrieval returns zero results
- WHEN `answer/4` runs
- THEN `outcome` is `:no_evidence`

##### Scenario: All-below-threshold yields no-evidence
- GIVEN every retrieved result scores below `0.35`
- WHEN `answer/4` runs
- THEN `outcome` is `:no_evidence`

##### Scenario: At least one sufficient result proceeds to synthesis
- GIVEN at least one retrieved result scores at or above `0.35` and the index is fresh
- WHEN `answer/4` runs
- THEN synthesis is attempted

#### Requirement: No General-Knowledge Fallback on a Block (#232, ADR-010 decision 4)

On `:no_evidence` or `:stale` the system MUST NOT synthesize from model knowledge and MUST NOT produce a partial answer.

##### Scenario: Blocking outcomes contain no answer prose
- GIVEN a `:no_evidence` or `:stale` outcome
- WHEN the result is returned
- THEN it contains no answer prose and explicitly states the record does not support / is not ready

#### Requirement: Per-Patient and Cross-Tenant Isolation (#232, #234)

Retrieval and synthesis MUST be scoped to the consulted patient only. No chunk, excerpt, or source from another patient or another professional's tenant MAY appear in a result, end to end through the LiveView.

##### Scenario: Cross-patient isolation
- GIVEN two patients of the same professional
- WHEN patient A is consulted
- THEN every returned source resolves to patient A

##### Scenario: Cross-tenant isolation
- GIVEN patients belonging to different professionals
- WHEN one professional consults their patient
- THEN no other professional's patient data is retrievable through the consultation surface

#### Requirement: Tombstoned Material Stays Excluded (#232)

A consultation MUST NOT surface an excerpt from tombstoned or legally deleted clinical material as a source.

##### Scenario: Orphan chunk from a non-pending deletion job is not cited
- GIVEN a resource whose legal-deletion job is `cancelled`/`discarded` (outside `@pending_states`), leaving an orphan retrievable chunk
- WHEN the patient is consulted
- THEN that chunk's content is not returned as a source

#### Requirement: Visible Synthesis / Fuentes Separation (#234, ADR-010 decisions 2–3)

The first real response surface MUST visibly separate a "Síntesis basada en evidencia" section from a "Fuentes" section. Each source MUST render its exact excerpt, kind, date, and stable reference.

##### Scenario: Synthesis and sources are distinct sections
- GIVEN a `:synthesis` result from the real pipeline
- WHEN it renders
- THEN the synthesis text and the sources list appear as visually distinct, labeled sections

##### Scenario: Each source renders excerpt, kind, date, reference
- GIVEN a rendered source
- WHEN it is inspected
- THEN the exact excerpt, a kind label, a date, and a stable reference/link are all present

##### Scenario: Provider error renders a safe state
- GIVEN `:provider_failure` from the real pipeline
- WHEN it renders
- THEN a safe error state shows with no partial synthesis and no sources

#### Requirement: ClinicalSearch Retirement — Hard Cutover (#234, D5)

`AletheaWeb.PatientLive.ClinicalSearch` route and its navigation entry MUST be removed so the consultation chat is the single primary surface for navigating the clinical record. No coexisting ungated ranked-list surface MAY remain.

##### Scenario: Retired route no longer resolves to the ranked list
- GIVEN the retired path `/patients/:patient_id/clinical-search`
- WHEN a professional requests it
- THEN it no longer resolves to the ranked-fragment surface

##### Scenario: Navigation offers the chat as the primary surface
- GIVEN patient navigation
- WHEN it renders
- THEN no "clinical search" entry appears and the consultation chat is the primary entry

### Explicitly Out of Scope (no requirements written)

Hypothesis / "Hipótesis para revisar" behavior (D1); `:cloud` synthesis or any external-provider path (D2); threshold recalibration away from 0.35 (D3); a narrower / relevance-aware freshness signal (D4); flagged coexistence of chat and clinical search (D5); any persistence of threads, conversation content, or access/audit metadata; reuse of `Alethea.AI.ConversationMemory`; changes to indexing, chunking, embeddings, the outbox worker, retention, or tombstoning; changes to `Retrieval.search/4` ranking semantics; response streaming; multi-patient or cross-patient consultation; patient-facing access; export of a consultation answer; fixing `source_occurred_at` for clinical notes.

### Assumptions forced by proposal ambiguity

- "Complete indexed history" is the whole-patient chunk table as search space, but only the top-50 ANN candidates are scored — a recall bound, accepted as-is.
- `source_occurred_at` for clinical notes derives from `inserted_at`, so a citation date may reflect authoring time rather than event time. Not fixed here; scenarios assert the field is present, not that it is a true event date.
