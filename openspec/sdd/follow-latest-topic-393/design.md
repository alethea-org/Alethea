# Design: Follow the latest topic and close exploration gently (#393)

## Technical Approach

The model emits a leading marker in its single existing generation call. `JournalingReply` strips that marker before `guard/2` runs. Code then counts questions, reads the stretch state from the same bounded snapshot used for history, and enforces the three-question limit with closing and acknowledgement copy. Two nullable, non-PHI columns on the reply row carry the stretch state forward.

The pure logic lives in one new module, `Alethea.Telegram.TopicExploration`. `JournalingReply` keeps its role as the only seam: `TelegramBurstReplyWorker` is its sole caller (`telegram_burst_reply_worker.ex:125`), and the only other call, `generate/3`, delegates to `generate_burst/2` (`journaling_reply.ex:64-66`).

## Pipeline (anchors verified on `main`)

```
JournalingReply.generate_burst/2 (journaling_reply.ex:89)
 1 legacy patient resolved once (now shared by history + state)
 2 state = Clinical.exploration_state(legacy, earliest, anchor.session_id)   NEW
 3 mode  = TopicExploration.mode(state)                                     NEW
 4 request += exploration_mode: mode           (journaling_reply.ex:98-102)
 5 ai_worker().process(request) -> raw text    (journaling_reply.ex:104)
 6 {new?, text} = TopicExploration.parse_marker(raw)  NEW, BEFORE guard
     text == "" -> {:error, :empty_response}
 7 guard(%{res | response: text}, anchor)      (journaling_reply.ex:122-138, unchanged)
 8 TopicExploration.enforce(guarded, state, new?, anchor.id)  NEW -> adds :exploration
TelegramBurstReplyWorker.run_save_transaction/6 (L166-207)
 9 Clinical.save_telegram_reply(..., session_id, chain_result.exploration)  (L180-186)
```

The raw model text first becomes available at `guided_conversation_chain.ex:147` (`response: message.content`). Parsing happens after the worker boundary, in `JournalingReply`, so that `PhiWorkerMock` tests exercise the parser. The chain stays a dumb transport.

## 1. Marker protocol

`TopicExploration.parse_marker/1 :: String.t() -> {new_situation :: boolean(), String.t()}`

| Step | Logic |
|---|---|
| Leading marker | `~r/\A\s*<<\s*(NUEVO|SIGUE)\s*>>/iu`. `new_situation = (capture == NUEVO)` |
| Strip everywhere | `~r/<<[^<>\n]{0,20}>>/u` → `""`. A patient-facing reply never legitimately contains `<<…>>`. |
| Unclosed leading fragment (truncation) | `~r/\A\s*<<[A-Za-z]*\s*/u` → `""` |
| Normalize | `String.trim/1` |
| Missing, malformed, or misplaced marker | `new_situation = false` (Q5: fails toward closing) |

The constants `@new_marker "<<NUEVO>>"` and `@same_marker "<<SIGUE>>"` are defined in `Alethea.AI.JournalingPrompt`, which renders them, and exposed through `JournalingPrompt.markers/0`. `TopicExploration` (Telegram) reads them from there, so the dependency runs Telegram→AI, the same direction `JournalingReply` already uses, and the strings exist in one place only. A truncated reply keeps its leading marker, which is then parsed. After that the reply goes to `:incomplete` and is replaced by the fallback.

## 2. State read and columns

`turns_before/3` (`clinical.ex:882-896`) is private. It has no session filter. It excludes `superseded` (L885) and is bounded strictly before `current`, ordered by timestamp, then direction, then id (L886-893). Its where-clauses are extracted into a private `before_snapshot(query, patient_id, current)` helper. Both `turns_before/3` and the new read below use that helper. This is a refactor that does not change behavior.

```elixir
@spec exploration_state(Accounts.Patient.t(), Message.t(), binary() | nil) ::
        %{questions: 0..3, closing_invitation_sent: boolean()}
```

The query takes the newest `direction == "outbound"` row in `before_snapshot(legacy.id, earliest)` (`limit 1`). It does not decrypt anything and does not need the DEK.

| Newest outbound row | Result |
|---|---|
| none | fresh `%{questions: 0, closing_invitation_sent: false}` |
| `behavior_type == "crisis_bypass"` (Q1) | fresh |
| `session_id != current_session_id`, or current session is `nil` (Q2) | fresh |
| `exploration_questions` is `nil` (legacy row) | fresh |
| otherwise | its stored values |

`failed` and `ambiguous` rows count (Q3). The predicate matches the history filter. Retry stability follows from that: an absorbed pending reply sorts after its own member, so it falls outside the snapshot. `current_session_id` is `anchor.session_id`, which is always set for Telegram inbounds (`telegram_message_worker.ex:346`).

**Migration** (generated with `mix ecto.gen.migration add_exploration_state_to_messages`). It follows the `change/0` and `create constraint` idiom of `20261006040546_add_delivery_state_to_messages.exs:24-35`:

```elixir
alter table(:messages) do
  add :exploration_questions, :smallint
  add :closing_invitation_sent, :boolean
end
create constraint(:messages, :messages_exploration_questions_check,
  check: "exploration_questions IS NULL OR exploration_questions BETWEEN 0 AND 3")
```

In `message.ex`, `field :exploration_questions, :integer` and `field :closing_invitation_sent, :boolean` are added with a comment block in the style of L19-23. They are set programmatically and are never cast. `save_telegram_reply/6` gains `exploration \\ nil` (`clinical.ex:306`). When the value is non-nil, it is applied with `put_change` for both columns. The crisis caller (`telegram_message_worker.ex:704-710`) is unchanged and writes `NULL`.

## 3. Decision logic (`TopicExploration.enforce/4`)

`mode/1` returns `:closing` when `questions >= 3` and `:open` otherwise. `q? = String.contains?(text, ["?", "¿"])`.

| Marker | State | Response | Persisted `{questions, sent}` |
|---|---|---|---|
| NUEVO | any | unchanged | `{q? 1 : 0, false}` |
| SIGUE/none | n < 3 | unchanged | `{n + (q? 1 : 0), false}` |
| SIGUE/none | 3, not sent | if q?: `JournalingFallback.closing_for_inbound/1` | `{3, true}` |
| SIGUE/none | 3, sent | if q?: `JournalingFallback.acknowledgement_for_inbound/1` | `{3, true}` |

When a substitution happens, `:model_version` is set to `"journaling-fallback"` and `:guardrail` is left untouched. The result gains `exploration: %{exploration_questions:, closing_invitation_sent:, new_situation:}`.

**Interaction with the guard:** this is a separate layer that runs after `guard/2`. The guard's diagnostic/prescriptive/incomplete dispatch never learns about the mode. The neutral fallback from the guard either counts as a question (n < 3) or is replaced by closing or acknowledgement copy (at the limit). The closing invitation never counts toward the limit.

## 4. Prompt

`system_prompt(:open | :closing)` returns one of two compile-time `@` attributes. `system_prompt/0` returns `system_prompt(:open)`, which keeps `guided_conversation_chain.ex:44` and the chain test L69 working. Both variants are static, and no patient data is interpolated. The existing rule "como máximo UNA pregunta" (L70) stays in place.

New sections are inserted after `# Forma de cada respuesta`:

- `# Seguir el tema actual`:
  - Follow the most recent situation.
  - Never revive topics the patient left behind unless they bring them up again.
  - With several topics in one message, acknowledge them in one sentence and ask only about the last one.
  - Ask at most three questions in total about the same situation.
- `# Marcador de situación`: "Empieza siempre tu respuesta con <<NUEVO>> si la persona trae una situación nueva (o es lo primero que cuenta), o con <<SIGUE>> si sigue con la misma. Escríbelo exactamente así, una sola vez y solo al principio; la persona no lo ve."
- `# Cierre de la exploración` (`:closing` only): "Con <<SIGUE>>: no hagas ninguna pregunta; reconoce brevemente y, si aún no lo hiciste, invita con suavidad a contar otra cosa cuando quiera. Si ya la invitaste, solo reconoce. Con <<NUEVO>>: sigue las reglas normales."

Examples gain `marker: "<<NUEVO>>" | "<<SIGUE>>"` and render as `Alethea: <<MARKER>> text`. Two examples are added:

- `:follow_up` (SIGUE)
- `:multi_topic`: patient `"Hoy me retaron en el trabajo por un informe.\n\nY en la noche discutí con mi pareja."`, Alethea `<<NUEVO>> Gracias por contarme lo del trabajo y lo de tu pareja. ¿Qué pasó en esa discusión?`

## 5. Contract changes

The `PhiWorkerBehaviour` request type (L11-15) gains `exploration_mode: :open | :closing`. `PhiWorker.process/1` (L17-22) and the chain's `run/1` (L30) read the key with `Map.get(params, :exploration_mode, :open)`, so the existing chain and phi_worker tests keep passing.

Three existing tests need deliberate updates:

- `telegram_message_worker_guardrails_test.exs:132` changes to `[:exploration_mode, :history, :message_id, :sanitized_content]`.
- In `journaling_prompt_test.exs`, the heading list (L24-31) adds the two new headings, and a closing variant adds a third.
- In `journaling_prompt_test.exs`, the example situations (L109-117) and the rendering assertion (L122-123) now include the marker.

## 6. Fallback

`variants/0` is unchanged: it still has 4 entries and each one asks a question. Two new lists are added, each with 2 entries chosen by `:erlang.phash2`, and none of them contains `?` or `¿`:

- `@closing_invitations`: "Gracias por todo lo que me contaste sobre esto. Cuando quieras, puedes contarme otra cosa de tu día."
- `@acknowledgements`: "Gracias, queda registrado."

One shared closing set is enough, because the guard reason is irrelevant to the layer in section 3.

## Architecture Decisions

| Decision | Choice | Rejected | Rationale |
|---|---|---|---|
| AD1 Signal | Leading marker in the same call | JSON output; a second classifier call | A marker survives truncation at the 160-token cap and costs about 4 tokens. A second call doubles latency, and a topic classifier is story 30, which is out of scope. |
| AD2 Strip site | `JournalingReply`, before `guard/2` | Stripping in the chain | The mock replaces the chain, so parsing must sit after the boundary to be testable. Also, neither the guard nor persistence should ever see marker syntax. |
| AD3 Guard vs. closing | An independent layer after the guard | Making the guard closing-aware | The guard's concern (clinical wording) stays separate from the exploration concern (questions). One set of closing copy works for every block reason. |
| AD4 Multi-topic | A prompt rule plus an example only | Labelling the joined members | Counting is per reply, and a NUEVO or SIGUE marker on the latest topic is the correct semantics. Labels risk being echoed (exploration). No code is needed. |
| AD5 Session reset | Compare `session_id` of the newest snapshot reply with `anchor.session_id` | Filtering history by session | History is deliberately not session-bounded (L882). The comparison needs no new query beyond `limit 1`. |
| AD6 State read site | Inside `generate_burst/2` | Reading in the worker and passing state in | `JournalingReply` already owns the snapshot (L101, L149-162), and the `generate_burst/2` signature stays the same. |
| AD7 Post-closing | The two-value mode is kept; the prompt and history handle "don't re-invite" | A third `:closed` mode | The proposal locked `:open`/`:closing`. Code enforces only "no question". |

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit | `parse_marker/1` (leading, same-line, own-line, lowercase, spaced, misplaced, malformed, unclosed, missing, marker-only empty) and the `enforce/4` table | Pure, `async: true`, `test/alethea/telegram/topic_exploration_test.exs` |
| Unit | Closing and acknowledgement copy passes `JournalingOutputGuard` and has no `?`/`¿` | `journaling_fallback_test.exs` |
| Unit | Both prompt variants: headings, static, rules, examples with markers | `journaling_prompt_test.exs` |
| Integration (DB) | `exploration_state/3`: crisis reset, session reset, legacy `nil`, superseded skipped, failed/ambiguous counted, bounded at earliest | `test/alethea/clinical/exploration_state_test.exs` |
| Worker entry | Count 0→1, 2→3. At 3: closing copy substituted, or model text kept. Post-closing: acknowledgement. NUEVO resets after closing. Missing marker counts. Guard block under the limit counts, and at the limit becomes closing copy. Truncated NUEVO. Multi-member burst with NUEVO. `exploration_mode: :closing` in the payload. Marker never appears in the persisted body, the job body, or `ai_diagnoses.ai_response`. Sentiment regression: `EmotionAnalysisWorker` is still enqueued. | New `test/alethea/jobs/telegram_topic_exploration_test.exs`: `TelegramMessageWorker.perform/1` → `run_burst_reply/0`, `PhiWorkerMock` returning marker-prefixed text, a prior outbound seeded in the current open session (`SessionManager.current_open_session/1`) with `delivery_state: "sent"` so it is not absorbed |

## Threat Matrix

N/A: the change has no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

The migration is additive and nullable, so legacy rows read as fresh. The down migration drops the constraint and the columns. Ship as a feature-branch chain and land on `main` once at the end, following the #391 precedent (`495c340`). Intermediate slices must not reach patients, because a marker prompt without the stripping code would leak markers.

## Review Workload Forecast

| Area | Lines (est.) |
|---|---|
| Production code (migration 30, schema 8, clinical 60, TopicExploration 110, JournalingReply 40, fallback 35, prompt 70, behaviour/chain/phi_worker 20, worker 10) | ~385 |
| Tests (prompt 60, guardrails 2, TopicExploration 150, fallback 25, exploration_state 90, worker-entry 350) | ~675 |
| **Total** | **~1060** |

#391's slices overran their budgets by 71–124%, so a realistic total is 1600–2300 lines.

- Decision needed before apply: Yes
- Chained PRs recommended: Yes
- 400-line budget risk: High

Proposed chain (feature branch):

1. **S1:** migration, schema, `exploration_state/3`, `save_telegram_reply/6`, DB tests. Inert.
2. **S2:** `TopicExploration` and fallback variants, with unit tests. Inert.
3. **S3:** `JournalingReply` and worker wiring, `exploration_mode` plumbing, the guardrails L132 update, and core worker-entry tests.
4. **S4:** the prompt variants and their test, plus the reset, multi-topic, and retry worker-entry tests.

Even S3 risks going over 400 lines and may need to be split.

## Open Questions

- [ ] The column names (`exploration_questions`, `closing_invitation_sent`) must be reconciled with spec.md, which is being written in parallel.
- [ ] Whether the post-closing "no repeated invitation" rule depends only on the prompt (code enforces only "no question"). The spec should not demand deterministic detection of the invitation wording.
