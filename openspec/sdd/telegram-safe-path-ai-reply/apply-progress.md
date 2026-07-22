# Apply Progress — telegram-safe-path-ai-reply (PR-A, #84) — Round 2 correction

Bounded surgical fix for two both-judge-confirmed SEVERE findings, plus one
cheap test-strengthening item, on branch
`feat/telegram-safe-path-ai-reply-pr-a-safe-path-phiworker` (HEAD 57f4901).

## Work units

### FIX 1 — Atomicity / no fabricated clinical record

- File: `lib/alethea/jobs/telegram_message_worker.ex`
- Function: `persist_and_enqueue_outbound/6` (was ~lines 202-233)
- Change: wrapped the outbound `Clinical.save_telegram_message/6` insert and
  `Clinical.save_ai_diagnosis/2` insert in a single `Repo.transaction/1`. On
  diagnosis-save failure the transaction calls `Repo.rollback/1`, unwinding
  the outbound `Message` row too. `enqueue_outbound/6` only runs after the
  transaction returns `{:ok, outbound}`. Fail-loud preserved: `{:error,
  reason}` still raises so Oban retries.
- Added `Repo` to the module's `alias Alethea.{Accounts, Clinical, Repo}`.
- Test: `test/alethea/jobs/telegram_message_worker_test.exs`, extended
  "diagnosis-save failure raises BEFORE enqueueing TelegramOutboundWorker"
  with an assertion that `Repo.aggregate(from(m in Message, where:
  m.direction == "outbound"), :count) == 0` after the failed attempt.
- RED (pre-fix, via `git stash` of the two lib files): `outbound_count ==
  1` (orphaned committed row) — assertion failed as expected.
- GREEN (post-fix): full suite green, `outbound_count == 0`.

### FIX 2 — PHI leak via inspect

- (a) File: `lib/alethea/ai/diagnosis.ex` — added
  `@derive {Inspect, except: [:ai_response, :extracted_emotions]}` on the
  `Alethea.AI.Diagnosis` schema, placed immediately before `schema
  "ai_diagnoses" do` (correct Ecto placement, ahead of the generated
  `defstruct`). Protects every `inspect/1` call site on this struct,
  including the WhatsApp pipeline.
- (b) File: `lib/alethea/jobs/telegram_message_worker.ex` — the raise in
  `persist_and_enqueue_outbound/6` reporting a persistence failure no
  longer embeds `inspect(reason)` directly (which, for an `Ecto.Changeset`,
  includes the full `changes` map — plaintext `ai_response`). Added a
  `safe_reason/1` private helper: for `%Ecto.Changeset{}` it renders only
  the failed field keys (`errors |> Keyword.keys() |> Enum.uniq() |>
  inspect()`); any other reason falls back to `inspect/1` (non-changeset
  reasons carry no PHI).
- Test: added "diagnosis-save failure error message does NOT leak the
  plaintext AI reply (PHI hygiene, Round 2 SEVERE fix)" — sets
  `chain_result.response` to a unique sentinel string and asserts
  `error.message` (raised `RuntimeError`) does not contain it.
- RED (pre-fix): assertion failed — sentinel string was present in the
  raised message via `inspect(reason)`.
- GREEN (post-fix): sentinel absent from the raised message.

### FIX 3 — strengthen sentiment regression test (ghost assertion)

- File: `test/alethea/jobs/telegram_message_worker_test.exs`
- Test: "safe path still feeds the sentiment pipeline (regression) ...
  passes its id to PhiWorker" (~lines 293-320)
- Change: the `PhiWorkerMock.expect(:process, fn %{message_id: mid} -> ...
  end)` callback now `send(self(), {:phi_worker_process_mid, mid})`; after
  `perform/1` returns, the test asserts `mid == inbound.id` via
  `assert_receive`. Previously `mid` was destructured but never compared
  against the actual inbound message id — a regression that passed a
  stray id would have gone undetected.
- This one was GREEN both before and after (the worker already forwarded
  the correct id) — the change only strengthens the test's proof, no
  production code changed for this item.

## Out of scope (untouched, per delegate prompt)

- `:ai_llm` seam (PR-B scope)
- `handle_crisis_path/8`
- Pre-existing inbound `telegram_message_id` retry `MatchError` (existing
  "inbound persistence failure raises" test, unchanged)
- At-rest encryption of `ai_response` (separate follow-up)

## Verification

- `mix test test/alethea/jobs/telegram_message_worker_test.exs --seed 0`:
  36/36 passed (RED confirmed first via `git stash` of the two lib files,
  then GREEN after `git stash pop`).
- `mix precommit` (compile --warnings-as-errors, format, full test suite):
  exit 0, `578 passed (2 doctests, 576 tests), 5 skipped`, 0 failures.
- `git diff --stat`: only `lib/alethea/ai/diagnosis.ex`,
  `lib/alethea/jobs/telegram_message_worker.ex`, and
  `test/alethea/jobs/telegram_message_worker_test.exs` touched.

## Ledger status

Both both-judge-confirmed SEVERE findings (atomicity, PHI-leak-via-inspect)
and the cheap ghost-assertion item: **fixed**. No new problems surfaced
during the fix; nothing else logged.
