# telegram-topic-exploration Specification

## Purpose

Alethea follows the patient's latest topic, asks at most three exploratory questions per topic stretch, then closes gently. Code counts and enforces. The model only signals new vs same situation.

## Definitions

| Term | Meaning |
|------|---------|
| Snapshot | History `generate_burst/2` already reads: bounded at the earliest burst member, `superseded` excluded, `failed`/`ambiguous` included |
| Counted reply | Latest ordinary (non-`crisis_bypass`) reply in the snapshot carrying exploration metadata |
| Question | Final reply text containing `?` or `¿`, except the closing invitation |

## Requirements

### Requirement: Marker Signal

The model's first output line MUST be `<<NUEVO>>` or `<<SIGUE>>`. The system MUST strip any marker, wherever it appears, before the guard, persistence, and delivery. A missing or malformed marker MUST be treated as `<<SIGUE>>`.

#### Scenario: Marker stripped
- GIVEN the model returns `<<SIGUE>>\n¿Qué sentiste?`
- WHEN the burst reply is saved and delivered
- THEN the saved row and outbound body equal `¿Qué sentiste?`

#### Scenario: Missing marker
- GIVEN stretch count 2 and the model returns no marker
- WHEN the reply asks a question
- THEN the stretch count becomes 3 (no reset)

### Requirement: Stretch State

The system MUST derive the stretch count from the counted reply in the snapshot. The count MUST start at 0 when: no counted reply exists; the marker is `<<NUEVO>>`; a `crisis_bypass` reply is newer than the counted reply; or the counted reply's `session_id` differs from the current session.

#### Scenario: Crisis resets
- GIVEN count 3, then a newer `crisis_bypass` reply in the snapshot
- WHEN the next ordinary reply is generated
- THEN `exploration_mode` is `:open` and the count restarts at 0

#### Scenario: New session resets
- GIVEN count 3 with a different `session_id`
- WHEN a reply is generated in the current session
- THEN `exploration_mode` is `:open`

#### Scenario: Reintroduced topic
- GIVEN an old topic Alethea stopped exploring
- WHEN the patient brings it back and the model emits `<<NUEVO>>`
- THEN the count restarts at 0, not the old stretch's count

### Requirement: Question Limit and Closing

The system MUST allow at most 3 questions per stretch. At count 3 under `<<SIGUE>>`, the reply MUST be a soft closing invitation with no question; any model question MUST be replaced with fixed closing copy. Fallback replies MUST count when they contain a question; at the limit, fallbacks MUST use closing variants.

#### Scenario: Fourth question becomes invitation
- GIVEN count 3 and `<<SIGUE>>`
- WHEN the model asks a question
- THEN the delivered reply is the closing invitation and the count stays 3

#### Scenario: Fallback counts
- GIVEN count 1 and a guard-triggered fallback with `?`
- WHEN saved
- THEN the count becomes 2

### Requirement: Post-Closing Persistence

After a closing invitation, further `<<SIGUE>>` replies in the same stretch MUST be a brief acknowledgement with no question and no repeated invitation.

#### Scenario: No nagging
- GIVEN the previous counted reply was the closing invitation
- WHEN the patient continues the same topic
- THEN the reply has no `?`/`¿` and is not the invitation

### Requirement: Multi-Topic Burst

A burst with several topics MUST receive brief acknowledgement of each and at most one question, about the latest topic only. Alethea MUST NOT revive abandoned topics.

#### Scenario: Latest topic
- GIVEN a burst about work then about sleep
- WHEN the reply is generated
- THEN at most one question appears, about sleep

### Requirement: Retry Stability

Only committed, not superseded replies MUST affect the count. Rolled-back or later-superseded attempts and asynchronous delivery-state changes MUST NOT change it.

#### Scenario: Retry after rollback
- GIVEN a save transaction rolled back
- WHEN the job retries
- THEN the computed mode and count match the first attempt

#### Scenario: Failed reply counts
- GIVEN the counted reply later becomes `failed`
- WHEN the next reply is generated
- THEN its count still applies

### Requirement: Request and Storage Contract

`PhiWorkerBehaviour`'s request MUST add `exploration_mode` (`:open`/`:closing`) and MUST NOT carry counts or patient data in it. Metadata MUST be new nullable non-PHI columns on `messages` (counts/flags only, never topic text), written inside `TelegramBurstReplyWorker`'s existing save transaction.

#### Scenario: Request shape
- GIVEN any burst
- WHEN `PhiWorkerMock.process/1` is called
- THEN the request has 4 keys and `exploration_mode` is `:open` or `:closing`

### Requirement: Scope Boundary

The system MUST NOT add a classifier, change crisis replies or copy, depend on #394, or store topic text. Crisis replies are read only for resets.

#### Scenario: Crisis untouched
- GIVEN a crisis message
- WHEN processed
- THEN the `crisis_bypass` reply is unchanged by this capability
