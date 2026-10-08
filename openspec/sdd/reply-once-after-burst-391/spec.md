# telegram-burst-reply Specification

## Purpose

Rapid ordinary Telegram messages stay individual records but get one reply after ~45s of inactivity. Stale replies are never sent. Crisis handling stays immediate. Modified capabilities: none (no `openspec/specs/` baseline). Out of scope: classifier (#396), crisis copy, `JournalingReply` safety rules/prompt (#392), recalling `sending`/`ambiguous` replies, non-Telegram channels.

## Requirements

| # | Requirement | Strength |
|---|-------------|----------|
| R1 | Window renewal | MUST |
| R2 | Burst coverage and order | MUST |
| R3 | Save-time staleness | MUST |
| R4 | Dispatch-time staleness | MUST |
| R5 | Crisis supersession | MUST |
| R6 | Coverage idempotency | MUST |
| R7 | Emotion analysis independence | MUST |
| R8 | History hygiene | MUST |
| R9 | Burst generation input | MUST |
| R10 | Pre-existing rows excluded | MUST |
| R11 | Pending-reply absorption | MUST |

### Requirement: R1 Window renewal

Each ordinary inbound MUST push the patient's single scheduled burst-reply job ~45s later; no reply MAY be generated before expiry.

#### Scenario: Renewal
- GIVEN a scheduled burst job for patient P
- WHEN another ordinary inbound for P is processed
- THEN exactly one scheduled burst job exists for P, due ~45s after the latest inbound
- AND no reply row exists yet

#### Scenario: Inbound during execution
- GIVEN P's burst job is executing
- WHEN a new ordinary inbound arrives
- THEN a new scheduled burst job is armed for P

### Requirement: R2 Burst coverage and order

One reply MUST cover every uncovered inbound of the burst, ordered by `telegram_message_id` as integer (not text, not `inserted_at`), and set each member's `replied_by_message_id` only where it IS NULL.

#### Scenario: Numeric order
- GIVEN uncovered inbound ids "9", "10", "11" inserted out of order
- WHEN the burst job runs
- THEN one reply covers all three, members ordered 9, 10, 11

### Requirement: R3 Save-time staleness

If a newer uncovered inbound arrived during generation, or any coverage update affects zero rows, the save MUST roll back entirely: no reply row, no diagnosis row, no fabricated record; the burst re-arms.

#### Scenario: Newer inbound during generation
- GIVEN generation is blocked in `PhiWorkerMock`
- WHEN a newer inbound is saved, then generation completes
- THEN no reply or diagnosis row exists, members stay uncovered, a burst job is scheduled

### Requirement: R4 Dispatch-time staleness

The outbound claim (after `Pacer.acquire`, on every retry) MUST fail when a newer uncovered inbound exists; the reply becomes `superseded`, is not sent, and its members' coverage is released.

#### Scenario: Superseded at claim
- GIVEN a `pending` burst reply and a newer uncovered inbound
- WHEN `TelegramOutboundWorker.perform/1` runs (first attempt or retry)
- THEN the fake client sends nothing, state is `superseded`, members are uncovered

### Requirement: R5 Crisis supersession

A deterministic crisis match MUST mark P's `pending` ordinary replies `superseded` and cover all uncovered inbound up to and including the crisis inbound, with crisis copy unchanged and never generated.

#### Scenario: Crisis mid-burst
- GIVEN uncovered inbound A, B and a `pending` ordinary reply
- WHEN crisis inbound C is processed
- THEN the ordinary reply is `superseded`, A, B, C are covered by the crisis reply, `PhiWorkerMock` is not called

#### Scenario: After crisis
- GIVEN a crisis reply covered C
- WHEN ordinary inbound D arrives
- THEN D starts a new burst

### Requirement: R6 Coverage idempotency

Each inbound MUST be covered by at most one patient-visible reply, including under overlapping burst jobs.

#### Scenario: Overlapping jobs
- GIVEN two burst jobs for P run concurrently on the same members
- WHEN both complete
- THEN exactly one reply row exists and one outbound job is enqueued

### Requirement: R7 Emotion analysis independence

The `:ai_analysis` job MUST be enqueued per inbound regardless of debounce or reply state (asserted, not rebuilt).

#### Scenario: Analysis during window
- GIVEN an ordinary inbound inside an open window
- WHEN the inbound worker completes
- THEN an `:ai_analysis` job for that message is enqueued

### Requirement: R8 History hygiene

`list_conversation_turns` MUST exclude `superseded` outbound rows.

#### Scenario: Superseded text hidden
- GIVEN a `superseded` reply and a `sent` reply
- WHEN conversation turns are listed
- THEN only the `sent` reply's text appears

### Requirement: R9 Burst generation input

`JournalingReply` MUST accept all covered members, sanitized, in order, exactly once; the anchor (`reply_to_message_id`) is the newest member. Guard, fallback, and prompt rules MUST NOT change.

#### Scenario: Members passed once
- GIVEN a burst of three members
- WHEN the reply is generated
- THEN `PhiWorkerMock` receives each member once, in order, and the anchor is the newest

### Requirement: R10 Pre-existing rows excluded

Inbound rows predating this change MUST NOT join any burst (marker mechanism is design's decision).

#### Scenario: Legacy backlog
- GIVEN unreplied inbound rows existing before migration
- WHEN the first post-migration burst job runs
- THEN its reply covers only post-migration inbound

### Requirement: R11 Pending-reply absorption

A new burst MUST also absorb the patient's still-`pending` ordinary reply, if any: that reply's covered members become members of the new burst too, and saving the new reply supersedes the old one. This refines R4's dispatch-only supersede — a `pending` reply delayed by a rate-limit retry MUST NOT be allowed to send after a newer reply has already answered more recent messages.

#### Scenario: Pending reply absorbed by a newer burst
- GIVEN ordinary reply R1 is `pending` and covers inbound A, B
- WHEN a new burst for the same patient (triggered by inbound C arriving after R1 was generated) runs before R1 is dispatched
- THEN R1 becomes `superseded`, and the new reply R2 covers A, B, and C
- AND `PhiWorkerMock` is never asked to regenerate content for A or B — the absorption is a coverage/state change only, not new generation
