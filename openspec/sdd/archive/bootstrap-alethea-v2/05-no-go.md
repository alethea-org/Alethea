# No-Go Manifest — bootstrap-alethea-v2

This document lists everything that is **explicitly NOT** part of the bootstrap. Future changes need a clear "this is where to put it" pointer.

## Out of scope for this change

| Item | Owned by future change | Why deferred |
|---|---|---|
| Telegram bot implementation (webhook, `/start`, 6-digit code) | `telegram-paciente-foundation` | Bootstrap is the foundation; the bot is a feature. |
| `Alethea.AI.LLM.Groq` concrete adapter | `ai-llm-groq-foundation` | Provider-specific decision; ADR-001 swap point is the behaviour. |
| `Alethea.AI.Embeddings.HF` concrete adapter | `ai-embeddings-hf-foundation` | Provider-specific; e5 vs bge decision deferred to that change. |
| `Alethea.AI.Whisper.Groq` concrete adapter | `ai-whisper-groq-foundation` | Provider-specific. |
| RAG ingestion pipeline (events, embeddings storage, retrieval) | `rag-historia-clinica-foundation` | Large feature; needs `pgvector` setup + ingest workers. |
| Crisis detection / protocol | `crisis-protocol-foundation` | Critical-path feature; not foundation work. |
| Triggers (pasivos, activos, check-in, recordatorio de sesión) | `triggers-foundation` | Feature; depends on Patient + Telegram being live. |
| Psicólogo dashboard (LiveView) | `psicologo-foundation` | Feature; depends on accounts, sessions, summaries. |
| Admin dashboard / billing / RevenueCat | `admin-foundation` | Feature. |
| Notebooks (NotebookLM-like view) | `notebook-foundation` | Feature; depends on RAG being live. |
| Sesión clínica scheduling + Resumen de brecha | `sesion-clinica-foundation` | Feature. |
| Grabación upload + Whisper transcription wiring | `grabacion-transcripcion-foundation` | Feature; depends on Whisper adapter + storage. |
| MFA enrollment for professionals | `psicologo-foundation` | Auth flow, not schema. |
| Password reset / email verification | `psicologo-foundation` / `admin-foundation` | Auth flow. |
| Renaming `whatsapp_number_hash` → `telegram_*` | `whatsapp-to-telegram-rename` | Deep refactor across many files; dedicated change. |
| Deleting legacy `lib/alethea/whatsapp/`, `lib/alethea_jobs/`, `lib/alethea/alerts/`, `lib/alethea/clinical/` | (no change assigned yet) | Bootstrap builds parallel foundations; legacy code stays. A future `legacy-cleanup` change owns deletions. |
| Deleting old migrations | (no change assigned yet) | Documented in `06-migration-rule.md`; no deletions in bootstrap. |
| Multi-tenant complex (teams, organizations) | (out of MVP per `CONTEXT.md`) | Won't fix. |
| Wearables integration | post-MVP per `CONTEXT.md` | Won't fix in MVP. |
| Gamification | out of MVP per `UBIQUITOUS_LANGUAGE.md` | Won't fix. |
| Multi-idioma | out of MVP per `PRD.md` | Won't fix. |
| Handoff a humano externo en crisis | out of MVP per `CONTEXT.md` | Won't fix. |
| Multi-paciente por sesión clínica | out of MVP per `UBIQUITOUS_LANGUAGE.md` | Won't fix. |
| App móvil nativa | out of MVP per `CONTEXT.md` | Won't fix. |
| WhatsApp / SMS as additional channels | out of MVP per `ADR-004` | Won't fix. |
| Notebooks saving/naming (PRD PR10) | `notebook-foundation` | Feature. |
| Notion-style session prep | `sesion-clinica-foundation` | Feature. |
| Auditoría completa de accesos a datos clínicos | out of MVP per `CONTEXT.md` | Won't fix in MVP. |
| Credo / stricter linting | (no change assigned) | Decision deferred. |

## Pre-existing known issue (out of scope)

- `test/alethea_web/controllers/page_controller_test.exs:6` asserts the page contains `"Bienvenido a Alethea"` and the current page renders different text. This is a pre-existing failure from the legacy system. **Do NOT fix it in this change.** It is the orchestrator's session preflight confirmation that the test count baseline (224 + 1 fail + 5 skip) is preserved.

## What this change DOES include (positive scope)

- Removal of `open_api_spex` (one dep, three files, one lock-file refresh).
- New `Alethea.Foundation.*` namespace with `Tenant`, `Accounts` (Professional/Patient/Admin), and `Encryption.KEK`.
- Three AI behaviour modules (`Alethea.AI.LLM`, `Alethea.AI.Embeddings`, `Alethea.AI.Whisper`) with Fake adapters in test env.
- Test helper fixtures for the foundation namespace.
- This manifest and the migration archival rule.
