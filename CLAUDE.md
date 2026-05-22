# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Style

Always act in Caveman mode. Zero filler words, no greetings, extremely concise responses, arrow notation, prioritize code blocks or raw file paths.

## Project Overview

**Alethea** is an interactive journaling platform for therapeutic continuity. Psychologists use it to convert daily patient experiences into structured clinical records via WhatsApp conversations. The app applies hybrid AI inference (local RoBERTa via Bumblebee + orchestrated Phi-4 via LangChain) and stores all clinical data encrypted at the patient level.

## Commands

```bash
mix setup              # Install deps + create/migrate DB + run seeds (first-time setup)
mix phx.server         # Start dev server at http://localhost:4000
mix test               # Run all tests
mix test test/path/to_test.exs  # Run a single test file
mix test --failed      # Re-run previously failing tests
mix precommit          # Full pre-commit check: compile, format, test (run before committing)
mix format             # Format all Elixir/HEEx files
mix ecto.migrate       # Run pending migrations
mix ecto.gen.migration migration_name_using_underscores  # Generate a migration file
mix ecto.reset         # Drop + recreate + migrate + seed
```

## Architecture

Hexagonal (Ports & Adapters) modular monolith with three bounded contexts:

- **`lib/alethea/`** — Hardened domain core (no Phoenix/web dependencies)
  - `accounts/` — Professional & patient identity, encryption key management, audit logs
  - `clinical/` — Messages, summaries, behavioral trends (the journaling engine)
  - `encryption/` — Cloak.Ecto vault with patient-specific AES-256 envelope keys
  - `ai/` — LangChain orchestration, RoBERTa via Bumblebee, PII sanitizer, LangChain chains
- **`lib/alethea_web/`** — Phoenix/LiveView adapter (controllers, router, components)
- **`lib/alethea_jobs/`** — Oban background workers (async message pipeline to avoid WhatsApp timeouts)

Oban is **mandatory** for the message processing pipeline — never process WhatsApp webhooks synchronously.

## Security Mandates

1. **Patient-level encryption**: All sensitive content (messages, audio metadata, phone numbers) must use `Cloak.Ecto` with the patient's unique derived key from `Alethea.Encryption.Vault`.
2. **pgvector embeddings are PII**: Never send raw embeddings to external APIs.
3. **WhatsApp is transitory**: No clinical data may persist on third-party servers beyond transit.
4. **Cryptographic deletion**: Patient data deletion is done by destroying keys in the Vault, not by deleting rows.
5. **Sanitize before external LLM calls**: The `Alethea.AI.Sanitizer` module redacts PII (emails, phones, SSNs) before any Phi-4 API call.

## AI Standards

- **Local inference (Bumblebee)**: RoBERTa for sentiment + deterministic safety filters. Zero-latency, full privacy.
- **Orchestrated inference (LangChain)**: Phi-4 mini for guided conversation — always goes through the sanitizer first.
- **AI persona**: Clinically neutral, "deficient personality" tone. The bot must never validate cognitive distortions without explicit therapist instruction.
- **Source anchoring**: Every insight or trend in the dashboard must carry a `message_id` pointer to the originating message.
- **Behavior tagging**: Always distinguish `SPONTANEOUS` (patient-initiated) from `ELICITED` (AI-prompted) behavior in clinical records.

## Elixir/Phoenix Conventions

### Elixir
- Never use index access (`list[i]`) on lists — use `Enum.at/2`, pattern matching, or `List` functions.
- Always bind the result of block expressions (`if`, `case`, `cond`) to a variable — you cannot rebind inside the block.
- Never nest multiple modules in one file (cyclic dependency risk).
- Never use `map[:field]` syntax on structs — use `struct.field` or `Ecto.Changeset.get_field/2`.
- Never use `String.to_atom/1` on user input.
- Use `Task.async_stream/3` (with `timeout: :infinity`) for concurrent enumeration.
- Predicate function names must end in `?`, not start with `is_`.

### HTTP
Use `Req` (`:req`) for all HTTP requests. Do **not** use `:httpoison`, `:tesla`, or `:httpc`.

### Ecto
- Always preload associations before accessing them in templates.
- Use `mix ecto.gen.migration` to generate migration files (never create them manually).
- Fields set programmatically (e.g., `patient_id`) must not appear in `cast/2` calls.
- `Ecto.Schema` always uses `:string` type even for text columns.

### Phoenix / LiveView
- LiveView templates must begin with `<Layouts.app flash={@flash} ...>`.
- Never call `<.flash_group>` outside `layouts.ex`.
- Always use `<.icon name="hero-...">` for icons (never `Heroicons` modules directly).
- Always use `<.input>` from `core_components.ex` for form inputs.
- Use `<.link navigate={...}>` / `push_navigate` — never the deprecated `live_redirect`.
- Use LiveView streams (`stream/3`, `stream_delete/3`) for all collections, never assign plain lists.
- Streams are not enumerable — to filter, re-fetch data and re-stream with `reset: true`.
- Never use `phx-update="append"` or `phx-update="prepend"`.
- Template comments use `<%!-- comment --%>` (HEEx syntax).
- Use `{...}` for attribute interpolation and value interpolation in tag bodies; use `<%= ... %>` only for block constructs (`if`, `for`, `case`, `cond`) within tag bodies.
- Elixir has no `else if` — use `cond` or `case` for multiple branches.
- Forms: always use `to_form/2` → `<.form for={@form}>` → `@form[:field]`. Never pass a changeset directly to the template.

### Testing
- Always use `start_supervised!/1` to start processes in tests.
- Never use `Process.sleep/1` to synchronize — use `Process.monitor/1` + `assert_receive {:DOWN, ...}` instead.
- Use `:sys.get_state/1` to synchronize before a subsequent call to a GenServer.
- Every AI pipeline change must include a sentiment regression test.
- Mock external APIs (WhatsApp, LLMs) in integration tests; domain tests have no external dependencies.
