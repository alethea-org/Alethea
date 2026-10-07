# Design: Reply once after a Telegram message burst (#391)

Grounded on `main` @ `8e3cbac`. All anchors are `file:line` on that tree.

## Technical Approach

The safe branch of `TelegramMessageWorker` (`lib/alethea/jobs/telegram_message_worker.ex:189-208`) stops generating. Instead it arms a per-patient `TelegramBurstReplyWorker`, delayed by 45s. Each later ordinary inbound pushes that job back. When the job runs, it collects every **uncovered** Telegram inbound for the patient, ordered by `telegram_message_id::bigint`, and generates one reply from it. Then, in one transaction, it saves the reply, claims coverage of those inbound rows, and enqueues delivery.

Coverage is the new `messages.replied_by_message_id`. The rules that use it:
- **Save time:** any uncovered inbound left after the claim rolls back the whole transaction.
- **Dispatch time:** the existing claim UPDATE becomes claim-or-supersede.
- **Crisis:** the crisis transaction supersedes pending ordinary replies and covers inbound up to the crisis message.
- **History:** `superseded` rows are filtered out.

**Invariant (I):** every uncovered inbound row has an armed burst job. A row stays uncovered until exactly one committed reply claims it through a conditional UPDATE.

## Verified anchors

| Claim | Evidence |
|---|---|
| Oban is 2.22.1 with the Basic engine | `mix.lock:29` |
| The default unique `period` is **60s on `inserted_at`** | `deps/oban/lib/oban/job.ex:232-238`, `put_unique` merges the defaults `:660-669`, `since_period` filters `deps/oban/lib/oban/engines/basic.ex:527-531` |
| `states: :scheduled` expands to `~w(scheduled)a` | `job.ex:441` |
| `replace` applies by the existing job's state | `basic.ex:450-459` |
| `replace` is accepted in `use Oban.Worker` | `deps/oban/lib/oban/worker.ex:64` |
| Under lock contention, an insert returns `conflict?: true` and neither inserts nor replaces | `basic.ex:437-440` (`pg_try_advisory_xact_lock`, `:533-541`) |
| `SessionTimeoutWorker` uses `unique: [fields: [:args], period: :infinity]` | `lib/alethea_jobs/session_timeout_worker.ex:107-112`; `replace` is passed to `new/2` at `telegram_message_worker.ex:455-458` |
| The PhiWorker request is `%{message_id, sanitized_content :: String.t(), history :: [turn]}` | `lib/alethea/ai/phi_worker_behaviour.ex:11-17` |
| The chain sends `history ++ [Message.new_user!(content)]` | `lib/alethea/ai/chains/guided_conversation_chain.ex:123-126` |
| `generate/3` takes one inbound and bounds history at it | `lib/alethea/telegram/journaling_reply.ex:58-77, 112-125` |
| The history query has no delivery-state filter | `lib/alethea/clinical.ex:599-612` |
| The claim is `move_telegram_delivery(id, ["pending"], sending)` | `clinical.ex:381-386, 477-485` |
| The delivery-state check constraint allows 5 states | `priv/repo/migrations/20261006040546_add_delivery_state_to_messages.exs:30-34` |
| The crisis transaction runs `update_patient`, then the diagnosis, then the reply | `telegram_message_worker.ex:794-815` |
| `update_patient` is a no-op UPDATE when `urgent_intervention` is already true, so it is **not** a reliable lock | Ecto skips the UPDATE when a changeset has no changes |
| `messages.patient_id` is the legacy patient (binary_id) | `lib/alethea/clinical/message.ex:6,31` |
| The `telegram_inbound` queue runs 10 jobs at a time | `config/config.exs:57` |

**The proposal's Oban config is unsafe as written.** Without `period: :infinity`, a burst longer than 60s stops matching its own scheduled job and inserts a second one. This is the same bug `SessionTimeoutWorker` documents at `:10-23`.

## Architecture Decisions

| # | Decision | Rejected | Rationale |
|---|---|---|---|
| AD1 | `use Oban.Worker, queue: :telegram_inbound, max_attempts: 3, unique: [keys: [:patient_id], period: :infinity, states: :scheduled], replace: [scheduled: [:scheduled_at]]` | A literal copy of `SessionTimeoutWorker` (`fields: [:args]` with the default states, which include `executing` and `completed`, so a completed job blocks every later burst forever). The proposal's version without `period` (60s horizon). | Uniqueness only among waiting jobs means an executing job never blocks a new arm. That is how a newer inbound re-arms. `replace` is declared on the worker so no call site can repeat the misplacement documented at `telegram_message_worker.ex:429-443`. |
| AD2 | Backfill pre-#391 inbound rows with `replied_by_message_id = id` (self-reference = "legacy, outside the burst model"). S3 adds a repair pass. | A sentinel UUID (breaks the FK). A separate boolean (a second column and a second predicate in every query). Truthful links only (rows that never got a reply would join the first burst). | One predicate (`IS NULL`) stays the single source of truth. A self-reference can never match a release (`= reply_id`) or absorb (`IN pending_ids`) predicate. |
| AD3 | Save-time staleness rolls back everything: no reply row, no diagnosis, no delivery job. | Save a `superseded` row. | #390's rule: no fabricated undelivered records (`telegram_message_worker.ex:268-276`). `superseded` exists only for rows that were genuine dispatch candidates. |
| AD4 | Re-arm after a rollback: the job calls `arm/1` itself. It is idempotent through AD1: if the newer inbound already armed a job, this one only replaces `scheduled_at`. | Rely only on the newer inbound's own arm. | That arm can be lost: the inbound job may crash between its row commit and the arm, or hit lock contention (`basic.ex:437-440`). A self-re-arm keeps invariant I. |
| AD5 | A burst also **absorbs** still-`pending` ordinary replies: members are rows that are uncovered OR covered by a pending `elicited` reply. Saving supersedes those replies. | Uncovered-only members. | Without it, a pending R1 delayed by a 429 is sent after the newer R2, out of order and stale. The absorb UPDATE (`pending→superseded`) and the dispatch claim (`pending→sending`) contend on the same row lock, so exactly one wins. If the claim wins, the absorb count mismatches, the transaction rolls back and re-arms, and the next run sees R1's members as covered. |
| AD6 | Per-patient mutex: the burst save transaction and the crisis transaction both start with `SELECT … FROM patients WHERE id = $1 FOR UPDATE` (`Clinical.lock_patient_conversation!/1`). | Rely on the crisis `update_patient` lock (not reliable, see the anchors). Classify crisis inside the burst job. | This serializes coverage writers. If crisis runs first, the burst's coverage count mismatches (the crisis covered the row), so it rolls back and re-arms. If the burst runs first, the crisis statements see R committed and absorb it. Lock order is always patient, then outbound rows, then inbound rows, so there is no deadlock with the dispatch transaction (outbound, then inbound). |
| AD7 | Dispatch decides claim-or-supersede in **one** UPDATE using a `CASE WHEN EXISTS(uncovered)`. Supersede releases coverage (`SET replied_by = NULL WHERE replied_by = R`) in the same transaction, and the outbound worker re-arms. | A separate claim, then a supersede (two snapshots, so a concurrent burst commit between them makes the decision on a stale view). | Race analysis: before the release commits, R's members are covered by R. After it commits, they are uncovered and an arm exists. The two never overlap because coverage only moves through `IS NULL`-guarded UPDATEs. A concurrent burst job either read before the release (its staleness check after its claim then sees the released rows, so it rolls back and re-arms) or after it (the rows are members). So there is no window where a row is uncovered and unarmed, and no window where it is double-covered. |
| AD8 | Multi-message input: members' sanitized texts are joined in order with `"\n\n"` into `sanitized_content`. `message_id` is the anchor (the newest member). | Change `PhiWorkerBehaviour`. Pass earlier members as history turns. | The contract is a single string for the current turn plus prior history (verified). Joining needs no contract change and does not consume the 10-turn history cap. |
| AD9 | Delivery is enqueued **inside** the save transaction (`Oban.insert` on the same Repo). | #390's post-commit enqueue plus a resume. | A burst job retry finds no uncovered rows, so it cannot resume a lost enqueue. Committing atomically removes that gap. |
| AD10 | In-flight replies (`sending`, `ambiguous`) are never recalled. | — | Accepted residual B. |

## Interfaces / Contracts

```elixir
# lib/alethea/jobs/telegram_burst_reply_worker.ex (new)
@window_seconds 45
@spec arm(%{patient_id: binary(), chat_id: integer(), chat_id_hash: String.t()}) :: :ok
# perform/1: resolve the patient via FoundationAccounts.lookup_patient_by_chat_hash/1 and
# check that patient.id == args.patient_id (otherwise :ok). Then:
#   members = Clinical.list_burst_members(foundation_patient)   # [{%Message{}, text}], tg-id order
#   []      -> :ok
#   members -> JournalingReply.generate_burst(foundation_patient, members) -> save transaction:
#     lock_patient_conversation!; save_telegram_reply(anchor, session = anchor.session_id || open);
#     supersede_absorbed(prior_ids) (count == length);  cover_members(member_ids, reply.id)
#     (count == length);  uncovered_inbound?(p) -> rollback(:stale);  save_ai_diagnosis(anchor.id);
#     Oban.insert(outbound job, lane :safe, prio 9, unique as telegram_message_worker.ex:617-620)
#   {:error, :stale | :coverage_lost | :reply_already_exists} -> arm(args); :ok
#   generation {:error, _} -> raise (Oban retry, same as today's :248-253)

# lib/alethea/telegram/journaling_reply.ex
@spec generate_burst(Patient.t(), [{Message.t(), String.t()}, ...]) :: {:ok, chain_result} | {:error, term()}
# generate/3 becomes: generate_burst(p, [{inbound, text}]).
# History is bounded at the earliest member by (timestamp, id), so no member appears in history.
# Guard and fallback use the anchor (List.last).
```

Core SQL (`Alethea.Clinical`):

```sql
-- burst members
WHERE patient_id=$p AND direction='inbound' AND telegram_message_id IS NOT NULL
  AND (replied_by_message_id IS NULL OR replied_by_message_id IN
       (SELECT id FROM messages WHERE patient_id=$p AND direction='outbound'
          AND behavior_type='elicited' AND delivery_state='pending'))
ORDER BY telegram_message_id::bigint
-- cover:   UPDATE … SET replied_by_message_id=$r WHERE id = ANY($ids)
--            AND (replied_by_message_id IS NULL OR replied_by_message_id = ANY($absorbed))
-- dispatch claim (replaces clinical.ex:382):
UPDATE messages m SET updated_at=now(), delivery_state = CASE WHEN EXISTS (SELECT 1 FROM messages i
   WHERE i.patient_id=m.patient_id AND i.direction='inbound' AND i.replied_by_message_id IS NULL)
   THEN 'superseded' ELSE 'sending' END
 WHERE m.id=$id AND m.delivery_state='pending' RETURNING m.delivery_state
```

`claim_telegram_delivery/1` returns `:claimed | :superseded | {:not_claimed, state}`. `begin_journaling_delivery/1` (`telegram_outbound_worker.ex:273-290`) maps `:superseded` to `arm/1` followed by `{:skip, "superseded"}`. Pacer ordering (`:138` then `:142`) is unchanged, so retries recheck too.

**Crisis** (adds to `telegram_message_worker.ex:794-815`, after the reply save). The order is:
1. Lock the patient conversation.
2. `pending_ids` = the patient's pending `elicited` replies.
3. Supersede them.
4. Cover with the crisis reply the inbound where `tg::bigint <= crisis_tg` AND (the row is NULL OR covered by a `pending_ids` reply).
5. Release the remaining coverage that points at `pending_ids`.
6. After commit, if anything was released, `arm/1`.

`resume_reply` (`:367`) adds `"superseded"` to its terminal states.

**History** (`clinical.ex:599-612`): add `where: is_nil(m.delivery_state) or m.delivery_state != "superseded"`.

## Data Flow

    inbound ─▶ TelegramMessageWorker ─ save row (uncovered) ─ emotion job (unchanged :183)
                  ├─ :safe   ─▶ TelegramBurstReplyWorker.arm (+45s, replace)
                  └─ :crisis ─▶ tx[lock, reply, supersede pending, cover ≤ crisis]
    BurstReply ─ members ─ generate_burst ─ tx[lock, reply, absorb, cover, stale?, diag, enqueue]
                                             └─ rollback ─▶ arm
    OutboundWorker ─ Pacer ─ claim CASE ─ sending ─▶ send
                                       └ superseded ─ release ─▶ arm

## File Changes

| File | Action | Slice |
|---|---|---|
| `priv/repo/migrations/*_add_burst_coverage_to_messages.exs` | Create: nullable `replied_by_message_id` referencing `messages` (`on_delete: :nothing`); partial index `(patient_id) WHERE direction='inbound' AND replied_by_message_id IS NULL`; index `(replied_by_message_id) WHERE NOT NULL`; replace the check constraint with one that includes `'superseded'`; `up` backfills `SET replied_by_message_id=id WHERE direction='inbound'`; `down` drops everything and restores the 5-state check | S1 |
| `lib/alethea/clinical/message.ex` | `belongs_to :replied_by_message` (never cast) | S1 |
| `lib/alethea/clinical.ex` | Typedoc `superseded`, history filter, `list_burst_members/1` | S1 |
| `lib/alethea/telegram/journaling_reply.ex` | `generate_burst/2`; `generate/3` delegates to it | S1 |
| `lib/alethea/jobs/telegram_burst_reply_worker.ex` | Create (inert: no arm caller) | S2 |
| `lib/alethea/clinical.ex` | `lock_patient_conversation!/1`, absorb, cover, `uncovered_inbound?/1`, crisis supersede | S2 |
| `lib/alethea/jobs/telegram_message_worker.ex` | Crisis supersession (live; in sync mode no reply has covered members, so nothing is released) | S2 |
| `priv/repo/migrations/*_repair_burst_coverage.exs` | Rows NULL between S1 and S3: `SET replied_by = COALESCE(reply.id, id)` | S3 |
| `lib/alethea/jobs/telegram_message_worker.ex` | Safe path arms the job; delete `handle_safe_path`/`persist_and_enqueue_outbound` (`:226-331`) | S3 |
| `lib/alethea/clinical.ex`, `telegram_outbound_worker.ex` | Claim CASE, release, re-arm | S3 |
| `test/alethea/jobs/telegram_*_test.exs` | Move the sync-reply assertions (idempotency 7, guardrails 5, worker 14, reminder 1 Mock sites) to drive the burst job | S3 |

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Migration | Backfill: pre-existing inbound rows are self-covered and never become members. S3 repair links replied rows. | Insert rows, run `up`, assert `list_burst_members == []` |
| Unit | `generate_burst`: order, each member sanitized once, anchor `message_id`, history bound | `PhiWorkerMock` expectation on the request |
| Unit | History excludes `superseded` | Extend `test/alethea/clinical_test.exs:101` |
| Integration | Window renewal: one scheduled job, `scheduled_at` strictly later | `TelegramMessageWorker.perform/1` ×2 + `all_enqueued` (`SessionTimeoutWorker` renewal precedent) |
| Integration | Burst coverage/order: 3 inbound processed out of order, one reply, `replied_by` set on all three, anchor = max tg id | `perform/1` ×3, then `perform_job(TelegramBurstReplyWorker)` |
| Integration | Save-time stale: an inbound arrives during generation, so no reply, no diagnosis, no delivery job, and a re-armed job exists | Mock blocks on `:release`; insert the inbound while it is held |
| Integration | Dispatch stale: reply pending, newer inbound, `TelegramOutboundWorker.perform/1`, no send, `superseded`, coverage released, armed. The same on a retry job (`_attempt: 2`). | `Client.Fake` sent-log empty |
| Integration | Absorb: pending R1 plus a new burst means R1 is superseded and R2 covers all | `perform_job` |
| Integration | Crisis mid-burst: pending ordinary reply superseded, crisis covers ≤ crisis, crisis lane enqueued | `perform/1` with crisis text |
| Concurrency | Overlapping burst jobs give exactly one reply. A dispatch claim racing a burst absorb gives exactly one winner. | `Task.async` + `:release` (idempotency test `:227-248`) |
| Regression | Emotion job per inbound, independent of the burst; an existing sentiment regression test passes | `all_enqueued(worker: EmotionAnalysisWorker)` |

## Threat Matrix

N/A: no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

S1: additive migration with backfill. S3: repair migration. The rollback down-migration fails while any `superseded` rows exist; map them to `failed` first, or keep the column.

## Review Workload Forecast

| Slice | Est. changed lines | Content |
|---|---|---|
| S1 schema + read side (behavior-preserving) | ~300 | Migration, schema, history filter, `list_burst_members`, `generate_burst`, tests |
| S2 burst worker (inert) + crisis supersession | ~640 | Worker, transaction primitives, crisis, worker and race tests |
| S3 switch | ~730 | Safe path swap (−130/+30), claim CASE, release, repair migration, rewrite of 27 existing Mock sites, end-to-end tests |
| **Total** | **~1,670** | With repo overrun precedent (12–97%), plausibly 1,900–3,300 |

**Decision: a 3-PR chain.** The boundary follows a real hazard. Turning on dispatch staleness while sync generation is live would supersede per-message replies, release their rows, and orphan them. So the claim CASE must ship in the same slice as the switch (S3). S2 may split again (worker vs. crisis) if apply exceeds 600.

## Open Questions

- [ ] Should model input be capped for very large bursts (for example after an outage)? Today every member is supplied.
- [ ] The spec must state AD5 (absorbing pending replies). It refines the proposal's dispatch-only supersede.
