# Proposal — grounded-clinical-chat-initial (#223)

**Status:** proposal complete — all product decisions locked (D1–D5), ready for spec + design
**Date:** 2026-09-10
**Parent issue:** #223 — Consulta clínica fundamentada inicial (implementation projection of approved spec #221)
**Sub-issues:** #226 (contract) → #227 (LiveView shell) → #232 (retrieval + freshness) → #234 (initial response + retirement)
**Authority:** ADR-010 (6 numbered domain decisions), ADR-003, `openspec/UBIQUITOUS_LANGUAGE.md`, spec issue #221
**Prior phase:** `openspec/sdd/grounded-clinical-chat-initial/exploration.md`

## 1. Intent

### Problem

The psychologist already has a semantically navigable clinical history (the RAG delivered in #196), but the only way to interrogate it is `AletheaWeb.PatientLive.ClinicalSearch`: a ranked list of chunks. That surface answers "which fragments mention X", never "what does this patient's record say about X". The professional is left to do the synthesis manually, fragment by fragment, before every session.

The obvious fix — put a chat over the index — is exactly the thing that is dangerous without a contract. ADR-010 exists because an unconstrained conversational layer can (a) blend general model knowledge with the patient's record, (b) present a claim without traceable provenance, or (c) answer confidently while the patient's index is mid-update. Any of the three produces something that reads like a reliable clinical conclusion and is not one.

### Why now

Spec #221 is approved and ADR-010 is accepted. The retrieval, freshness, tombstone-exclusion and per-patient isolation primitives all landed in #196/#197 and are live. The domain contract exists on paper and the substrate exists in code; what is missing is the orchestration seam between them.

### What success looks like

An authorized psychologist opens one of their patients, asks a clinical question in natural language, and gets back a response that visibly separates **Síntesis basada en evidencia** from **Fuentes**, where every source is an exact excerpt from that patient's indexed history with its kind, its date and a stable reference. When the record does not support an answer, the chat says so and stops — it never fills the gap with general knowledge. When the patient's index has pending work, the chat blocks and asks the professional to retry, showing how many jobs are pending. Nothing about the conversation is persisted. `PatientLive.ClinicalSearch` is gone, and the chat is the single primary surface for navigating the clinical record.

## 2. Locked product decisions (D1–D5)

These were open forks at the start of this phase and have been **answered by the user**. They are binding on `sdd-spec` and `sdd-design`.

### D1 — Hypothesis mode: DEFERRED

This parent (#223) delivers **only** "Síntesis basada en evidencia" + "Fuentes". ADR-010 decision 2's additional "Hipótesis para revisar" block is explicitly out of scope for all four slices.

Deferred because it needs its own slice: an interpretive-request classification rule (when does a question warrant a hypothesis rather than a synthesis?), its own visual differentiation from the synthesis, and its own safety review — a hypothesis is neither a diagnosis nor a therapeutic recommendation, and the surface must make that unmistakable.

**Binding on spec:** the spec must not assert any hypothesis behaviour. **Consequence to state openly:** ADR-010 decision 2 is only partly delivered by this parent; the remainder needs a follow-up issue.

### D2 — Synthesis LLM provider: `:local` (phi4-mini)

Decrypted clinical narrative never leaves the box. `:cloud` is **rejected** for this chain.

Rationale: `Alethea.AI.Sanitizer.sanitize/1` redacts structured PII (email, phone, SSN, document id) but not free-form clinical text, so sanitizing does not make a clinical note safe to export. The excerpts this chain handles are the highest-sensitivity payload in the system — verbatim decrypted clinical record content. `:local` is also the established default (`config/config.exs:149`, `config/dev.exs:86`).

**Binding on design:** `Alethea.AI.Chains.ClinicalConsultationChain` pins/defaults to `:local`, and its `supported_providers/0` returns `[:local]` only — a `:cloud` misconfiguration must be impossible rather than merely discouraged. **Accepted cost:** phi4-mini produces weaker synthesis prose than a frontier cloud model.

### D3 — Evidence-sufficiency threshold: in the contract, config-exposed, initial value 0.35

The threshold moves out of the view and into the `Alethea.ClinicalRecord.Consultation` contract, exposed via application config, with an initial value of **0.35** — behaviour-compatible with today's hardcoded `@relevance_threshold` at `clinical_search.ex:69`.

Rationale: `Retrieval.search/4` is a pure ranking function with no cutoff, so evidence sufficiency is a domain judgment that must be named and owned somewhere. Contract placement makes it a documented decision instead of a view detail; config exposure allows recalibration without a deploy. Keeping 0.35 means this change introduces **no** behavioural drift in what counts as "no evidence" — any future shift is a deliberate decision, not an artifact of the migration.

**Calibration is deferred to real-data tuning.** The `ClinicalSearch` view's hardcoded constant is removed when that surface is retired in #234 (see D5), leaving exactly one owner of the value.

### D4 — Freshness granularity: global-per-patient, accepted as-is

`Retrieval.freshness/1` counts *any* pending `ClinicalRecordOutboxWorker` job for the patient (`available` / `scheduled` / `executing` / `retryable`), so one queued item blocks all consultation for that patient until the queue drains.

Accepted because it matches ADR-010 decision 5 literally and errs in the conservative direction — block rather than answer from a partial index. A narrower, relevance-aware pending signal is **not** in this parent.

**Binding mitigation:** the `:stale` outcome carries the `pending` job count, and the LiveView surfaces it, so the block is explainable and visibly transient rather than an unexplained refusal.

### D5 — ClinicalSearch retirement: hard cutover in #234

No flagged coexistence. A second, ungated surface would let a professional route around the freshness gate and the no-evidence block by falling back to the ranked list — precisely the failure ADR-010 forbids when it rejects "mantener una búsqueda clínica separada del chat".

**Binding on #234:** remove the route (`router.ex:127`), the navigation entry, the `PatientLive.ClinicalSearch` module and its threshold constant. **Accepted cost:** no rollback path if the chat underperforms on real questions; mitigated by #234 landing last, after #232 has proven retrieval behaviour against real data.

## 3. Scope

### In scope — 4 vertical slices

Each slice is a separate PR under the 400-line review budget.

**#226 (A1) — Public orchestration contract.** New Phoenix-free `Alethea.ClinicalRecord.Consultation` context: behaviour + `answer/4` typed contract, `Consultation.Answer` and `Consultation.Source` structs, `Consultation.Fake`. The evidence-sufficiency threshold lands here, config-exposed at 0.35 (D3). New `Alethea.AI.Chains.ClinicalConsultationChain` skeleton with a grounding / no-fallback system prompt, `supported_providers/0 == [:local]` (D2), plus its Mox mock and the `LLMConfig` `:clinical_consultation` clause. Fixed outcome vocabulary: `:synthesis | :no_evidence | :stale | :provider_failure`, where `:stale` carries the `pending` count (D4). Tests prove all four outcomes via controlled fakes and prove the model cannot inject or mutate sources. No LiveView, no retrieval change.

**#227 (A2) — Authorized LiveView shell.** `AletheaWeb.ConsultationLive` + route inside the existing `:require_authenticated_professional` live_session, per-patient, authorizing on mount. Consumes `Consultation.Fake` only, so it ships before real retrieval exists. Renders every safe visible state: idle, retrieving, synthesis, indexed-no-evidence, stale-pending (with the `pending` count per D4), provider-error. Zero persistence — bounded follow-up context lives only in socket assigns and is discarded on navigate, remount, logout or new conversation (ADR-010 decision 6). No hypothesis block (D1). Does not retire clinical search yet.

**#232 (A3) — Real retrieval + freshness.** Implement `Consultation.Live`: authorize via `Accounts.get_patient_for_professional/2` **before** any retrieval, then a fresh `Retrieval.search/4` over the complete indexed history on **every** turn, then map the envelope to the outcome vocabulary — `freshness.stale?` → `:stale` with its `pending` count; nothing retrieved or nothing at or above the 0.35 sufficiency threshold → `:no_evidence`; otherwise synthesize. No general-knowledge fallback on either blocking outcome. Tests cover authorize-before-retrieve, fresh-per-turn, block semantics, cross-patient/tenant isolation and zero source mutation.

**#234 (A4) — First real response + retirement.** Point `ConsultationLive` at `Consultation.Live` in dev/prod config. Render the visible "Síntesis basada en evidencia" / "Fuentes" separation with exact excerpt, source kind, date and stable reference per source. Safe provider-error state. Execute the D5 hard cutover: remove the `PatientLive.ClinicalSearch` route, nav entry, module and its hardcoded threshold constant, so the chat becomes the single primary surface and D3's config value is the only owner of evidence sufficiency. Integration LiveView tests.

### Out of scope

- **Hypothesis mode ("Hipótesis para revisar", ADR-010 decision 2)** — deferred per D1; needs a future slice with interpretive-request classification and its own safety review.
- **Any persistence of conversation content, named threads, or access/audit metadata** — explicitly rejected by ADR-010 decision 6 and by ADR-010's rejected-alternatives list. `Alethea.AI.ConversationMemory` (the ETS store used by patient journaling) must **not** be reused here.
- **`:cloud` synthesis and any external-provider path for this chain** — rejected per D2.
- **A narrower / relevance-aware freshness signal** — out of this parent per D4.
- **Threshold recalibration** — 0.35 is carried forward unchanged; tuning is deferred to real data per D3.
- **Flagged coexistence of chat and clinical search** — rejected per D5.
- **Changes to indexing, chunking, embeddings, the outbox worker, retention or tombstoning.** This change is read-only over the existing index.
- **Changes to `Retrieval.search/4` ranking semantics.** Evidence sufficiency is layered above retrieval, not pushed into it.
- **Response streaming**, multi-patient or cross-patient consultation, patient-facing access, and any export of a consultation answer.
- **Fixing `source_occurred_at` for clinical notes** (derived from `inserted_at`, pre-existing from #196). Tracked as a risk, not fixed here.

## 4. Approach

**Approach A from the exploration.** New `Alethea.ClinicalRecord.Consultation` context — a behaviour plus typed result structs — with LLM synthesis isolated behind a new `Alethea.AI.Chains.ClinicalConsultationChain`.

```
ConsultationLive (adapter)
  └─> Alethea.ClinicalRecord.Consultation.answer/4        # behaviour, swappable
        ├─ Consultation.Fake                              # test/#227
        └─ Consultation.Live
             ├─ Accounts.get_patient_for_professional/2   # authorize FIRST
             ├─ Rag.Retrieval.search/4                    # fresh, every turn
             ├─ freshness gate (D4) + sufficiency 0.35 (D3)
             │                                            # -> :stale | :no_evidence
             └─ AI.Chains.ClinicalConsultationChain       # :local only (D2)
                                                          # synthesis prose ONLY
   => %Answer{outcome, synthesis, sources: [%Source{}], pending}
```

### Rationale

- **Seam location is `lib/alethea/clinical_record/consultation/`, not `lib/alethea/ai/`.** Authorization, retrieval and freshness gating are ClinicalRecord read concerns that belong beside `Rag.Retrieval`; only the synthesis step delegates to `Alethea.AI`. This keeps the hexagonal core Phoenix-free and keeps clinical orchestration out of the adapter/discovery namespace.
- **A named struct with an `outcome` atom, not 4-variant tagged tuples.** #226 asks for a deep public interface with a fixed outcome vocabulary. An `%Answer{}` gives exhaustive downstream matching and one stable vocabulary the LiveView, the tests and future surfaces all share. The alternative (Approach B, `{:ok, :synthesis, map} | {:no_evidence, map} | ...` on an existing module) is lighter but weakly typed at exactly the place where a missed branch means answering during a block.
- **Sources are always derived server-side from the `Retrieval.search/4` envelope.** The chain receives already-retrieved excerpts and returns synthesis prose; it never returns a source list. ADR-010 decision 3 ("citas derivadas en servidor") therefore holds *by construction*, not by prompt discipline — the model has no channel through which to fabricate a citation.
- **Controlled fakes reuse the mechanism already proven in #195.** `config :alethea, :clinical_consultation` / `:clinical_consultation_chain` + `Mox.defmock(..., for: ChainBehaviour)`, exactly as `PatternProposalChain` does today. This is what lets #227 ship a fully tested shell before #232 exists.
- **Two behaviours (Consultation + Chain) is deliberate, not accidental indirection.** The Consultation behaviour swaps the whole orchestration for the shell slice; the Chain behaviour swaps only the LLM for the domain tests. Collapsing them would force #227 to depend on real retrieval.
- **`supported_providers/0 == [:local]` is a structural guarantee, not a default.** Under D2, an external-provider path for this chain should be impossible to configure, not merely discouraged.

### Key architectural decisions

1. Authorize before retrieve, on every turn — never trust a patient id from params.
2. Fresh retrieval on every turn over the complete indexed history. Conversation history resolves follow-up phrasing only; it is never evidence (ADR-010 decision 1).
3. Freshness is a hard gate, not a warning. `stale? == true` → `:stale`, no synthesis attempt (ADR-010 decision 5), carrying the `pending` count so the block is explainable (D4).
4. No general-knowledge fallback on `:no_evidence` or `:stale`, and no partial answer (ADR-010 decision 4).
5. Ephemeral by construction: socket assigns only, no ETS, no DB, no browser storage, no access metadata (ADR-010 decision 6).
6. Evidence sufficiency lives in the domain contract, config-exposed at 0.35, with a single owner once #234 removes the view constant (D3, D5).
7. Synthesis is local-only; decrypted clinical narrative never crosses a process boundary to an external provider (D2).
8. The response surface is Síntesis + Fuentes only — no hypothesis block anywhere in the four slices (D1).
9. Tombstone/discarded exclusion stays at index build time. The normal path needs no query-time re-filter; freshness covers the delete-propagation window.

## 5. Risks

All five product forks are now closed; what remains is implementation and consequence risk.

1. **Threshold calibration is deferred, not solved (D3).** 0.35 was chosen for behaviour compatibility, not because it was validated. Too high produces false blocks (the record contains the answer, the chat refuses); too low produces false answers (weakly related fragments synthesized into a confident-looking claim). Real-data tuning is a follow-up, and the config seam exists precisely so it can happen without a deploy.
2. **Persistence temptation.** `ConversationMemory` (ETS) is the obvious tool for follow-ups and is forbidden here. Needs an explicit test that no consultation state survives remount.
3. **Synthesis quality under `:local` (D2).** phi4-mini is materially weaker than a frontier model at summarizing clinical narrative. If real-use synthesis proves inadequate, the answer is a better local model — not relaxing D2.
4. **Global freshness blocking (D4).** Correct per ADR-010 but potentially confusing in daily use; the `pending` count mitigates but does not eliminate the surprise of a patient being wholly unqueryable while their queue drains.
5. **No rollback after the hard cutover (D5).** Once #234 removes ClinicalSearch there is no fallback surface. Mitigated by sequencing #234 last, after #232 has proven retrieval behaviour.
6. **Orphan-chunk edge case.** An Oban `cancelled` or `discarded` legal-deletion job is outside `@pending_states`, leaving a retrievable chunk that freshness will not flag. Consider a query-time `Tombstone` cross-check or at minimum an explicit scenario in #232.
7. **Partial ADR-010 coverage (D1).** Deferring hypothesis mode means decision 2 ships only partly delivered; this should be stated in the change record, not left implicit.
8. **Misleading citation dates.** `source_occurred_at` for clinical notes derives from `inserted_at`, not a real clinical event date (pre-existing from #196). Citations may show when the note was written rather than when the event occurred.
9. **Recall bound.** Only the top-50 ANN candidates are scored, so "complete indexed history" is structurally true of the search space but bounded in practice. Acceptable, but should be stated in the spec rather than implied.
10. **Four-slice sequencing.** #227 depends on #226's fake, #234 on #232's real implementation. Out-of-order merges break the shell. Each PR must stay under the 400-line review budget.

## 6. Next

`sdd-spec` and `sdd-design` can run in parallel. D1, D3 and D5 constrain what the spec asserts (no hypothesis behaviour; 0.35 sufficiency in the contract; retirement as an acceptance criterion of #234). D2 and D4 constrain the design (`:local`-only chain with `supported_providers/0 == [:local]`; `pending` count carried on the `:stale` outcome).
