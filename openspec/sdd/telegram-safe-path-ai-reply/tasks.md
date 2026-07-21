# Tasks — telegram-safe-path-ai-reply

**Change:** telegram-safe-path-ai-reply (issue #84) | **Store:** hybrid (mirrored to Engram `sdd/telegram-safe-path-ai-reply/tasks`)
**Mode:** Strict TDD — every task is RED (failing test first) → GREEN (minimum code to pass) → REFACTOR (cleanup, still green).
**Test runner:** `mix test` (single file: `mix test path/to_test.exs`).
**Inputs:** `spec.md`, `design.md`, project skill `langchain-elixir`.

## Delivery grouping (see §Review Workload Forecast for rationale)

- **PR-A** (sequential, Tasks 1–6): route the Telegram safe path through `phi_worker().process/1`, resolve persistence ordering, migrate the worker test suite to `PhiWorkerMock`. The `:ai_llm` seam becomes fully unreferenced in production code by the end of PR-A but is **not yet deleted**.
- **PR-B** (sequential, depends on PR-A merged; Task 7): delete the now-orphaned `:ai_llm` seam and its tests entirely.
- **Gate** (Task 8): run after PR-A and again after PR-B — `mix precommit` green.

---

## Task 1 — Add `phi_worker/0` port lookup and route `handle_safe_path/6` through it

**Satisfies:** "Safe-Path Reply via Shared PhiWorker Seam", "PII Sanitization Before External LLM Call" (spec.md domain: telegram-messaging).

**Files:**
- Impl: `lib/alethea/jobs/telegram_message_worker.ex`
- Test: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: In the "happy path safe clinical round-trip" describe block, rewrite the test `"calls the LLM via Alethea.AI.llm().chat/2 with the patient context"` to instead stub `Alethea.AI.PhiWorkerMock |> expect(:process, fn %{message_id: mid, raw_content: text, patient_context: ctx} -> ... {:ok, %{response: "respuesta clínica", source_message_id: mid, model_version: "phi-4-mini", behavior_type: :elicited}} end)` and assert the map-shape call (per design §5.2). Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — expect failure (worker still calls `AI.llm().chat/2`, no mock expectation is met / old assertions reference `{:llm_called, messages}` which will never arrive).
- GREEN:
  - Add `defp phi_worker, do: Application.get_env(:alethea, :phi_worker, Alethea.AI.PhiWorker)` near the top of the module (mirror WhatsApp's `ProcessMessageWorker` line 18).
  - Rewrite `handle_safe_path/6` (lines ~157–189) to call `phi_worker().process(%{message_id: inbound.id, raw_content: text, patient_context: context})` instead of building `messages` via `build_llm_messages/2` and calling `AI.llm().chat(messages, [])`. Match `{:ok, %{response: reply} = chain_result} when is_binary(reply) and reply != ""` → delegate to `persist_and_enqueue_outbound/6` (rewired in Task 2); keep the two failure clauses for Task 4.
  - Run the test file again — the migrated happy-path test should pass. (Other tests in the file will still fail until Tasks 2–6 land; run only the specific test with `mix test test/alethea/jobs/telegram_message_worker_test.exs:<line>` to confirm this one is green in isolation.)
- REFACTOR: Confirm `phi_worker/0` is placed consistently with other port-lookup helpers (`out_enqueue/0`) in the module; no behavior change.

**Parallel/Sequential:** Sequential — first task in PR-A, all subsequent worker tasks build on this rewrite.

---

## Task 2 — Persistence ordering: save outbound → save diagnosis → enqueue; delete `build_llm_messages/2`

**Satisfies:** "AI Diagnosis Anchored to Inbound Message", "Persistence Ordering — Save, Diagnose, Then Enqueue" (spec.md).

**Files:**
- Impl: `lib/alethea/jobs/telegram_message_worker.ex`
- Test: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: Extend the happy-path assertions so the existing "persists the outbound Message..." and "enqueues a TelegramOutboundWorker..." tests still exercise the new `chain_result`-based call signature (they should already be routed through Task 1's `PhiWorkerMock` stub — no new test file needed yet beyond keeping these two green through the transition). Run the suite — expect failures because `persist_and_enqueue_outbound/6` still expects a raw `reply` string, not `chain_result`, and still ignores diagnosis persistence.
- GREEN:
  - Rewrite `persist_and_enqueue_outbound/6` to accept `chain_result` (not a bare `reply` string) per design §2.2:
    ```elixir
    defp persist_and_enqueue_outbound(foundation_patient, chat_id, chat_id_hash, hash_prefix, chain_result, inbound_message_id) do
      reply = chain_result.response

      with {:ok, outbound} <-
             Clinical.save_telegram_message(foundation_patient, reply, "outbound", "elicited", nil),
           {:ok, _diagnosis} <-
             Clinical.save_ai_diagnosis(inbound_message_id, chain_result) do
        enqueue_outbound(chat_id_hash, chat_id, outbound.id, reply, hash_prefix, patient_id: foundation_patient.id)
        :ok
      else
        {:error, reason} ->
          raise "TelegramMessageWorker: failed to persist AI reply/diagnosis " <>
                  "(reason=#{inspect(reason)}, hash_prefix=#{hash_prefix})"
      end
    end
    ```
  - Update the call site in `handle_safe_path/6` (Task 1) to pass `chain_result` instead of `reply`.
  - Delete `build_llm_messages/2` (lines ~533–545) — no longer called.
  - Delete `alias Alethea.AI` (line 70) — no longer referenced now that `handle_safe_path/6` calls `phi_worker()` exclusively.
  - Update moduledoc step 7 wording: `Alethea.AI.llm().chat/2` → "route through `Alethea.AI.PhiWorker` (PII-sanitized, emotion-enriched) and anchor an `ai_diagnosis` to the inbound message" (design §2.3).
  - Run `mix test test/alethea/jobs/telegram_message_worker_test.exs` — all safe-path happy-path tests green.
- REFACTOR: Confirm `_ = inbound_message_id` (previously a no-op placeholder comment in the old `persist_and_enqueue_outbound/6`) is fully removed — `inbound_message_id` is now genuinely used by `save_ai_diagnosis/2`. Verify `mix compile --warnings-as-errors` is clean (no unused-alias warning for `Alethea.AI`).

**Parallel/Sequential:** Sequential — depends on Task 1's rewritten `handle_safe_path/6` call site.

---

## Task 3 — Diagnosis-anchor test + partial-failure ordering test

**Satisfies:** "AI Diagnosis Anchored to Inbound Message" (scenario: diagnosis persisted and anchored), "Persistence Ordering — Save, Diagnose, Then Enqueue" (scenario: diagnosis save fails — no double-send on retry).

**Files:**
- Test only: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: Add two new tests to the "happy path safe clinical round-trip" / "failure modes" describe blocks:
  1. **Diagnosis anchoring** — after a successful `perform/1` (via `PhiWorkerMock` stubbed happy path), query `Alethea.AI.Diagnosis` where `message_id == inbound.id` and assert `model_version == "phi-4-mini"`, `ai_response == "respuesta clínica"` (mirror the existing crisis-diagnosis assertion style at test lines ~405–426).
  2. **Partial-failure ordering** — stub `PhiWorkerMock` to return a valid `{:ok, chain_result}`, force `Clinical.save_ai_diagnosis/2` to fail (e.g., stub a `chain_result` whose `model_version`/shape trips the changeset, or inject a DB-level failure), then `assert_raise` and `refute_enqueued(worker: TelegramOutboundWorker)` — direct proof enqueue happens strictly after a successful diagnosis save (design §5.2).
  Run — both new tests should already pass if Task 2 landed cleanly (confirms Task 2's GREEN was correct), OR fail if the ordering/anchor logic has a gap — treat any failure here as a real RED signal requiring a Task 2 fix, not a test bug.
- GREEN: If either test fails, fix `persist_and_enqueue_outbound/6` (Task 2) until both pass. No new production code is expected if Task 2 was implemented per design.
- REFACTOR: none required beyond ensuring test naming/structure matches the file's existing describe-block conventions.

**Parallel/Sequential:** Depends on Task 2. Can run in parallel with Tasks 4–6 (different test cases, same file — sequence commits to avoid merge conflicts, but no logical dependency between them).

---

## Task 4 — Fail-loud tests: PhiWorker `{:error, _}` raises; empty-response guard raises

**Satisfies:** "LLM Failure Is Fail-Loud" (spec.md).

**Files:**
- Test only: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: Replace `"LLM unavailability raises (Oban retries the job)"` (currently uses `FailingLLM` + `Application.put_env(:alethea, :ai_llm, FailingLLM)`) with a `PhiWorkerMock`-driven version:
  ```elixir
  Alethea.AI.PhiWorkerMock |> expect(:process, fn _ -> {:error, :service_unavailable} end)
  assert_raise RuntimeError, ~r/service_unavailable/, fn -> TelegramMessageWorker.perform(%Oban.Job{args: args}) end
  refute_enqueued(worker: TelegramOutboundWorker)
  ```
  Add a new test for the empty-response guard: stub `PhiWorkerMock` to return `{:ok, %{response: ""}}` and assert the worker raises (design §3, `{:ok, %{response: ""}}` → `raise` clause already added in Task 1). Run — expect failure until the `FailingLLM`/`ai_llm` references are removed and PhiWorkerMock stubs are wired (this test currently still references `FailingLLM`, which will be deleted in Task 7 but must not be relied on here).
- GREEN: No new production code needed — the `{:error, reason}` and `{:ok, %{response: _empty}}` clauses were already added in Task 1's rewrite of `handle_safe_path/6`. Confirm both tests pass against that existing code.
- REFACTOR: none.

**Parallel/Sequential:** Depends on Task 1 (the raise clauses must already exist). Can run in parallel with Tasks 3, 5, 6.

---

## Task 5 — Sentiment regression test (ADR-D4)

**Satisfies:** "Sentiment Regression Test" (spec.md); ADR-D4 (design.md §6, §8).

**Files:**
- Test only: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: Add the test from design §6 verbatim (adapted to file conventions):
  ```elixir
  test "safe path still feeds the sentiment pipeline (regression): enqueues EmotionAnalysisWorker for the inbound message and passes its id to PhiWorker", ctx do
    Alethea.AI.PhiWorkerMock
    |> expect(:process, fn %{message_id: mid} ->
      {:ok, %{response: "ok", source_message_id: mid, model_version: "phi-4-mini", behavior_type: :elicited}}
    end)

    args = build_args("hola, buen día", telegram_message_id: 310, telegram_update_id: 31)
    assert :ok = TelegramMessageWorker.perform(%Oban.Job{args: args})

    inbound = Repo.one(from m in Message, where: m.direction == "inbound")
    assert_enqueued(worker: EmotionAnalysisWorker, args: %{message_id: inbound.id})
  end
  ```
  Run — should pass immediately if Tasks 1–2 preserved the pre-existing `enqueue_emotion_analysis(inbound.id, hash_prefix)` call unchanged (design confirms this call is untouched by the swap; the test's role is to pin it as regression coverage, not to drive new production code).
- GREEN: If it fails, the swap regressed the emotion-analysis enqueue or the `message_id` passed to `phi_worker().process/1` — fix `handle_safe_path/6` / `process_bound_message/5` to restore `inbound.id` as both the `EmotionAnalysisWorker` arg and the `PhiWorker` `message_id`.
- REFACTOR: none.

**Parallel/Sequential:** Depends on Tasks 1–2 landing (needs `PhiWorkerMock` wiring). Independent of Tasks 3, 4, 6 — same file, sequence commits to avoid conflicts.

---

## Task 6 — Crisis non-regression test: PhiWorkerMock NOT invoked on crisis path

**Satisfies:** "Crisis Path Non-Regression" (spec.md, both scenarios).

**Files:**
- Test only: `test/alethea/jobs/telegram_message_worker_test.exs`

**Steps:**
- RED: In the `"on :crisis classification, the LLM is NOT invoked"` test, remove `Application.put_env(:alethea, :ai_llm, ProbeLLM)` and the `refute_received {:llm_called, _}, 200` assertion. Do **not** add an explicit `expect`/`stub` on `PhiWorkerMock` — rely on `verify_on_exit!` (already in `setup`) to fail the test if `process/1` is ever called unexpectedly (design §5.2). Run the crisis describe block — should already pass since `handle_crisis_path/*` never calls `phi_worker()`; this task's RED step is really "confirm no regression," i.e., run once with `ProbeLLM` still present in the file (before Task 7 deletes it) to prove the assertion is redundant/safe, then remove it.
- GREEN: Test passes with no production code changes — `handle_crisis_path/8` was never touched by Tasks 1–2 (spec's "Crisis Path Non-Regression" requirement).
- REFACTOR: Optionally add an explicit `PhiWorkerMock |> expect(:process, 0, fn _ -> flunk("must not be called on crisis path") end)` for readability per design §5.2 (marked optional/redundant with `verify_on_exit!`).

**Parallel/Sequential:** Independent of Tasks 3–5 (different describe block). Must land before Task 7 deletes `ProbeLLM`/`FailingLLM` (this task is what makes those doubles safe to delete).

---

## Task 7 — Remove the `:ai_llm` seam entirely (PR-B)

**Satisfies:** REMOVED Requirement "`:ai_llm` Discovery Seam"; ADDED Requirement "Telegram Worker Tests Use Mox PhiWorkerMock" (spec.md domain: ai-discovery).

**Files:**
- Delete: `lib/alethea/ai/llm.ex` (`Alethea.AI.LLM` behaviour, 66 lines)
- Delete: `lib/alethea/ai/llm/fake.ex` (`Alethea.AI.LLM.Fake`, 42 lines)
- Delete: `test/alethea/ai/llm_test.exs` (whole file, 108 lines)
- Edit: `lib/alethea/ai.ex` — remove `llm/0` (`@doc`/`@spec`/`def`, lines 42–47); moduledoc "three slots" → "two slots" (drop the `:ai_llm` bullet at line 10 and the boundary-section reference to `{llm,…}` fakes at line 17)
- Edit: `config/test.exs` — delete line 96 (`config :alethea, :ai_llm, Alethea.AI.LLM.Fake`)
- Edit: `test/alethea/ai_test.exs` — delete the 2 `llm/0` tests (`"llm/0 returns the module configured at :ai_llm"` at lines 20–22, `"llm/0 raises with a clear error when :ai_llm is not configured"` at lines 34–46); keep embeddings/whisper tests untouched
- Edit: `test/alethea/ai/adapter_discovery_test.exs` — delete the `":ai_llm is configured to the LLM Fake"` test (lines 21–25); keep embeddings/whisper tests untouched
- Edit: `test/alethea/jobs/telegram_message_worker_test.exs` — delete `ProbeLLM` and `FailingLLM` module doubles (lines 52–67) and the `Application.put_env(:alethea, :ai_llm, Alethea.AI.LLM.Fake)` setup line (line 78)

**Preserve untouched (verify byte-for-byte):** `config/test.exs:37` (`:phi_worker`), `config/test.exs:97-98` (`:ai_embeddings`, `:ai_whisper`), `lib/alethea/ai/embeddings*`, `lib/alethea/ai/whisper*`, `Alethea.AI.LLMConfig` (`lib/alethea/ai/llm_config.ex`) and `test/alethea/ai/llm_config_test.exs`.

**Steps:**
- RED: This task is primarily deletion, so "RED" means: before deleting, run `mix test test/alethea/ai_test.exs test/alethea/ai/adapter_discovery_test.exs test/alethea/ai/llm_test.exs test/alethea/jobs/telegram_message_worker_test.exs` to confirm the current (pre-deletion) suite is green with Tasks 1–6 landed (i.e., the worker no longer calls `AI.llm()` in production but the seam files/tests still exist and pass). This is the checkpoint proving the seam is now provably orphaned.
- GREEN:
  1. Delete `lib/alethea/ai/llm.ex`, `lib/alethea/ai/llm/fake.ex`, `test/alethea/ai/llm_test.exs`.
  2. Edit `lib/alethea/ai.ex`: remove `llm/0` + its `@doc`/`@spec`; update moduledoc slot count and bullet list; **keep** `embeddings/0`, `whisper/0`, `configured!/1`.
  3. Edit `config/test.exs`: delete line 96 only; leave `:phi_worker`/`:ai_embeddings`/`:ai_whisper` lines untouched.
  4. Edit `test/alethea/ai_test.exs`: delete the 2 `llm/0` test blocks; keep the describe-block structure and embeddings/whisper tests intact.
  5. Edit `test/alethea/ai/adapter_discovery_test.exs`: delete the 1 `:ai_llm` test; keep the rest.
  6. Edit `test/alethea/jobs/telegram_message_worker_test.exs`: delete `ProbeLLM`/`FailingLLM` module defs and the `:ai_llm` setup line (already unreferenced after Tasks 4/6).
  7. Run `mix compile --warnings-as-errors` — must succeed (no dangling references to `Alethea.AI.LLM`/`Alethea.AI.LLM.Fake`).
  8. Run the full test suite for the touched files — must be green.
- REFACTOR / VERIFY: Run the design-mandated verification command:
  ```
  rg "ai_llm|Alethea\.AI\.LLM([^C]|$)|AI\.llm\(" lib test config
  ```
  Must return **zero hits** (the `[^C]` guard excludes `LLMConfig`). If any hit remains, it is a missed deletion — fix before proceeding.

**Parallel/Sequential:** Sequential, depends on all of Tasks 1–6 (PR-A) merged — the worker must be fully off `:ai_llm` before this seam can be safely deleted. This is PR-B.

---

## Task 8 — Final gate: `mix precommit` green

**Satisfies:** cross-cutting (no single requirement; delivery gate for both PR-A and PR-B).

**Files:** none (verification only).

**Steps:**
- Run `mix precommit` (compile --warnings-as-errors, format, full test suite) at the end of PR-A (after Task 6, before opening PR-A) and again at the end of PR-B (after Task 7).
- Confirm `mix format` produces no diff.
- Confirm `mix test` is fully green with no skipped/pending tests in the touched files.
- Confirm the Task 7 `rg` verification command (zero hits) as part of the PR-B gate.

**Parallel/Sequential:** Sequential — final step of each PR, blocking merge.

---

## Review Workload Forecast

**Estimated changed lines (added + removed, per unified-diff convention):**

| File | Est. lines changed | PR |
|---|---:|---|
| `lib/alethea/jobs/telegram_message_worker.ex` (Tasks 1–2: `phi_worker/0` add, `handle_safe_path/6` rewrite, `persist_and_enqueue_outbound/6` rewrite, `build_llm_messages/2` + `alias Alethea.AI` deletion, moduledoc edit) | ~155 | A |
| `test/alethea/jobs/telegram_message_worker_test.exs` (Tasks 1, 3–6: doubles removal, happy-path rewrite, 2 new tests, error-path rewrite, sentiment-regression test, crisis-test edit) | ~120 | A |
| **PR-A subtotal** | **~275** | |
| `lib/alethea/ai/llm.ex` (delete, whole file) | 66 | B |
| `lib/alethea/ai/llm/fake.ex` (delete, whole file) | 42 | B |
| `test/alethea/ai/llm_test.exs` (delete, whole file) | 108 | B |
| `lib/alethea/ai.ex` (remove `llm/0` + moduledoc edit) | ~20 | B |
| `test/alethea/ai_test.exs` (delete 2 tests) | ~20 | B |
| `test/alethea/ai/adapter_discovery_test.exs` (delete 1 test) | ~5 | B |
| `config/test.exs` (delete 1 line) | 1 | B |
| **PR-B subtotal** | **~262** | |
| **Combined total (if delivered as one PR)** | **~537** | |

**Chained PRs recommended: YES.** Splitting into PR-A (~275 lines) and PR-B (~262 lines) keeps each PR comfortably under the 400-line `review_budget_lines`; delivering as a single PR would land at ~537 lines, over budget. The split also matches a real dependency boundary (PR-B's deletion requires PR-A's rewrite to have already made `:ai_llm` fully unreferenced in production code — see Task 7's RED checkpoint), so the split is not just a line-count workaround but the natural sequencing point identified in design.md §4.

**400-line budget risk:** Each individual PR is under budget (~275 and ~262 respectively) — low risk per-PR. Risk is concentrated in PR-B being dominated by pure file deletions (216 of 262 lines are whole-file removals), which is low-complexity/low-risk content despite the raw line count — a `review-readability` or `review-risk` single-lens pass (per the standard-diff tier) should be sufficient for PR-B; PR-A carries the actual behavioral change (persistence ordering, fail-loud semantics) and is the higher-risk PR — `review-reliability` (behavior/state/regressions) is the dominant-risk lens for PR-A.

**Decision needed:** None blocking — recommendation is to proceed with the PR-A / PR-B split as scoped above (matches the task grouping already used in this file). Flag to the user only if they want a single combined PR despite the ~537-line combined estimate (would push into hot-path-adjacent territory requiring a 4R sweep instead of one lens).
