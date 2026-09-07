# Exploration: clinical-rag-projection (GitHub #196 — non-authoritative RAG projection/retrieval view)

**Phase:** sdd-explore
**Date:** 2026-09-02
**Status:** partial (ready for proposal, with flagged decisions)

## Current State

### Outbox producer (verified working)
`lib/alethea/clinical_record/outbox.ex` — `Outbox.event/2` allowlists `event/resource_type/resource_id/patient_id/professional_id` via `Map.take/2`. `lib/alethea/clinical_record.ex` (693 lines, confirmed) wraps every write in `Ecto.Multi` + `Oban.insert(:outbox_event, ...)`.

Actual events firing today: `target_behavior_created`, `clinical_note_created`, `consultation_evidence_created`, `clinician_observation_created`, `clinician_observation_updated`, `ai_proposal_accepted`, `ai_proposal_edited`, `ai_proposal_discarded`, `functional_analysis_draft_saved`.

No `ai_proposal_created` event (pending `AIProposal` rows are inserted later, by a not-yet-built `AIProposalWorker`, without an outbox emit). **No delete/tombstone event exists for any resource type.**

### Outbox consumer (confirmed no-op seam)
`lib/alethea_jobs/clinical_record_outbox_worker.ex` — `use Oban.Worker, queue: :clinical_record_outbox, max_attempts: 1`, `perform/1` pattern-matches the 5-key shape and returns `:ok` unconditionally. Locked in by `test/alethea_jobs/clinical_record_outbox_worker_test.exs`.

`max_attempts: 1` directly conflicts with the "idempotent retry" acceptance criterion — this is a real gap, not just an empty `perform/1` to fill in.

### Embeddings adapter — behaviour only
`lib/alethea/ai/embeddings.ex` (behaviour: `embed/2`, `model/0`, `dimensions/0`) — only concrete implementation is `lib/alethea/ai/embeddings/fake.ex`. Its moduledoc is **stale**: claims the production adapter is `Alethea.AI.Embeddings.HF` scoped to change `ai-embeddings-hf-foundation` — this directly contradicts ADR-002's 2026-09-02 revision (HF Inference reverted → local Ollama/BGE-M3).

`config :alethea, :ai_embeddings` exists **only in `config/test.exs`** — nothing in `config/dev.exs`/runtime config, so `Alethea.AI.embeddings/0` (`lib/alethea/ai.ex`) would raise `RuntimeError` outside `:test` today.

No Ollama embeddings HTTP client exists; the closest sibling pattern is `lib/alethea/ai/chat_models/ollama_chat.ex` (Req against `POST {endpoint}/api/chat`) — reusable *pattern* only, Ollama embeddings use a different endpoint (`/api/embeddings`).

### pgvector/DB — fully deferred
`lib/alethea/postgrex_types.ex` registers `Pgvector.Extensions.Vector` but nothing uses it. `priv/repo/migrations/20260526141108_add_sessions_and_embeddings.exs` explicitly defers `CREATE EXTENSION vector` + a `vector(384)` column as a manual future step — **384 is stale**, BGE-M3's dense output is 1024-dim; must not be copied forward.

No vector columns exist in the DB. No `tsvector`/full-text-search infrastructure exists anywhere either — the "hybrid retrieval" half of ADR-003/#193's stack is equally greenfield.

### Eligibility mapping (schema-verified, not inferred)

| Entity | Mutability | Outbox events | Eligibility signal |
|---|---|---|---|
| `TargetBehavior` | immutable | `_created` only | Not in ADR-003's explicit chunk-unit list — ambiguous whether it's semanticable content or just a label. |
| `ClinicalNote` | immutable, DB trigger blocks UPDATE | `_created` only | Clearly eligible. No replace/tombstone path exists despite ADR-003 mentioning "nota reemplazada." |
| `ConsultationEvidence` | immutable, DB trigger | `_created` only | Clearly eligible; carries `source_kind`/`source_id`/`occurred_at` for exact citation. |
| `ClinicianObservation` | mutable in place, no history kept | `_created` + `_updated` | Eligible, but "versioned" is questionable — an edit destroys prior text; re-embed must replace, not append. |
| `AIProposal` | soft-status (`pending/edited/accepted/discarded`) | only on accept/edit/discard | Schema's own moduledoc calls it "provisional-only... MUST NOT confirm evidence" — reads as always excluded, but whether `"accepted"` ever promotes it is undecided. |
| `FunctionalAnalysisDraft` | mutable upsert, "no version history, no second row" (design D4) | `_saved` on every save | Fails the "versioned" bar by its own docstring; it's a *clinician* draft not an *AI* draft, so the literal "AI drafts excluded" wording doesn't unambiguously cover it. |

### UI seam
`lib/alethea_web/live/target_behavior_live/review.ex` (`AletheaWeb.TargetBehaviorLive.Review`) — existing "clinical review workbench," thin shell over `Alethea.ClinicalRecord`, PubSub-driven, three-card-kind timeline. It is scoped to one `target_behavior_id`, not the whole patient — the issue's "retrieval view" likely needs a separate, patient-scoped entry point rather than extending this one directly.

### Ollama deployment (confirmed via docs)
`docs/main-demo-operator-guide.md` — operator manually runs Ollama, only `phi4-mini` is documented/verified (`curl .../api/tags`, `ollama list`). BGE-M3 is a separate model pull not mentioned in any ops doc today. `scripts/setup_telegram_demo.sh` explicitly never manages Ollama.

## Approaches

Not applicable — this phase is terrain-mapping only. One fork flagged for sdd-propose: whether `Alethea.AI.Embeddings.Ollama` ships inside this change's slice or as a separate prerequisite (code currently points at a stale change name, `ai-embeddings-hf-foundation`, for that adapter).

## Recommendation

N/A — investigation only. See Risks for what sdd-propose must decide.

## Risks

- No retry infra exists (`max_attempts: 1`) — conflicts with "idempotent retry" AC; needs a queue config change plus an idempotency/upsert key strategy.
- No tombstone/delete mechanism exists anywhere in `ClinicalRecord` (no schema field, no delete fn, no outbox event type) — the producing side is explicitly issue #197's scope, not yet built, so #196's "tombstoned material excluded" AC has no producer to test against yet.
- "Versioned" eligibility has no literal schema field to anchor to — must be operationally defined by sdd-propose.
- `AIProposal` (post-accept) and `FunctionalAnalysisDraft` eligibility are genuinely ambiguous at the boundary of "AI drafts... excluded."
- Scope boundary vs. ADR-003's "three voices": issue text scopes this to the `ClinicalRecord` outbox only (psychologist voice); patient-voice/system-voice content (`Alethea.Clinical` messages/summaries) has no outbox at all — a deliberate narrowing that should be stated explicitly in the proposal, not assumed.
- BGE-M3 not yet in any ops runbook; stale `vector(384)` dimension hint must not be copied (correct is 1024); `Alethea.AI.Embeddings.Fake`/`Embeddings` moduledocs actively point at a reverted decision (`Embeddings.HF`) and will mislead an implementer; `:ai_embeddings` unconfigured outside `:test` today.

## Ready for Proposal

Yes — with items above carried into sdd-propose as decisions, not re-investigation:

(a) eligibility for `TargetBehavior`/`AIProposal`-post-accept/`FunctionalAnalysisDraft`;
(b) whether the Ollama embeddings adapter ships in this change;
(c) idempotent-retry design against the current no-op consumer;
(d) tombstone placeholder stance given #197 hasn't landed;
(e) correct BGE-M3 dimension + full-text-search infra (both greenfield);
(f) where the patient-scoped retrieval view actually lives.

## Key Learnings

1. The `clinical_record_outbox` Oban queue is configured with `max_attempts: 1`, which structurally blocks the "idempotent retry" acceptance criterion until changed.
2. No schema in `lib/alethea/clinical_record/` has a delete, soft-delete, or tombstone field — that capability is entirely owned by not-yet-built issue #197.
3. `Alethea.AI.Embeddings.Fake` and `Alethea.AI.Embeddings` moduledocs still reference the reverted HF Inference API adapter, contradicting ADR-002's 2026-09-02 revision to local Ollama/BGE-M3.
4. The deferred pgvector migration comment sizes the embedding column at `vector(384)`, but BGE-M3's dense output is 1024-dimensional.
5. `AletheaWeb.TargetBehaviorLive.Review` is scoped to one target behavior, not a whole patient, so it is not a direct drop-in site for a patient-level retrieval view.
