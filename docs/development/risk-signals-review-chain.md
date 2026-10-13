# Review conservative Telegram risk signals as a feature chain

Keep the tracker draft and do not merge it into `main` until all child units are reviewed and integrated. Issue #396's integrated implementation remains preserved on `feat/396-conservative-risk-signals`; this chain exposes focused review boundaries without rewriting that history.

## Review order

Baseline: `main` at `295e9c3db341cf0b0dd2b6a7d1c53c3724ed4db6`.

| Unit | Branch | Review base | Outcome |
| --- | --- | --- | --- |
| Tracker | `feat/396-risk-signals-tracker` | `main` | Scope and review roadmap only |
| 1 | `feat/396-risk-signals-contract` | Tracker | Conservative deterministic-first signal contract and tests |
| 2 | `feat/396-risk-signals-persistence` | Unit 1 | Redacted inbound audit, fixed uncertainty delivery, independent alerts and replay safety |
| 3 | `feat/396-risk-signals-dashboard` | Unit 2 | Owned, deduplicated uncertainty notifications linking existing records |

Review each child against its immediate parent, not against the original pre-update base. This excludes unrelated changes already merged into `main`.

## Scope and verification

Rules remain authoritative. An existing pending, sent or ambiguous uncertainty reply is retained on confirmed-crisis replay; urgent intervention and crisis alerts still apply without another patient-visible reply. Audit and alert payloads omit patient text.

Classifier selection, evaluation and deployment, crisis protocol/copy redesign, and a new dashboard are out of scope. Existing running-summary privacy/scheduling and `CrisisCopy` behavior from `main` must remain intact.

Each unit needs its own applicable tests and native review disposition. The cohesive persistence/replay unit may exceed the approximately 400-line review target; disclose its actual size rather than omitting tests or manufacturing independently passing intermediate commits. Context fit must be verified natively, not inferred from line counts.

No child verification or publication is claimed by this roadmap. PR links, checks and review outcomes will be recorded when observed. The final child implementation must match the preserved integrated feature, excluding tracking-only documents.
