# Patient timezone delivery chain (#439)

Strategy: feature-branch-chain. This tracker is draft/no-merge until the child
changes are reviewed and integrated. No merge is authorized by publication.

## Review slices

| Position | Head | Base | Scope | Review lines |
| --- | --- | --- | --- | --- |
| Tracker | `feat/439-patient-timezone-tracker` | `main` | Delivery coordination only | This note |
| 1/3 | `feat/439-timezone-core` | `feat/439-patient-timezone-tracker` | IANA validation and explicit UTC/DST conversion | 238 |
| 2/3 | `feat/439-timezone-persistence` | `feat/439-timezone-core` | Patient/professional fields, inheritance and domain API | 432 |
| 3/3 | `feat/439-timezone-dashboard` | `feat/439-timezone-persistence` | Dashboard forms and closing verification evidence | 370 |

The persistence slice exceeds the advisory 400-line target by 32 lines. Keep
its migration, domain behavior, tests and documentation together; reviewers
should explicitly accept the small overage rather than drop coverage.

## Boundaries and evidence

- Foundation chat-id prerequisite #438 is already merged into `main` through
  PRs #455–#457. The tracker starts at `16ee726` with the same source tree as
  the implementation base `9823f7c`.
- Reviewed implementation commits remain unchanged: `d563c1e`, `caae2d4`,
  `a332813`, with closing evidence in `9de0b6e`.
- Final `mix precommit` passed: 2481 passed (6 doctests, 2475 tests),
  5 pre-existing skips. Independent verification passed S1–S6.
- Native four-lens review of the combined committed target was approved and
  acknowledged under `review-35e0b74aeac2a861`. Two informational readability
  suggestions in Foundation Accounts remain separate later work.
- Browser verification was unavailable. LiveView integration tests passed;
  HEEx LSP is unsupported and Accounts Dialyzer warnings were recorded.
- Existing session schedules remain UTC. No new trigger scheduler is included.
- `.github/workflows/elixir.yml` only runs on PRs targeting `main`; child PRs
  do not get automated jobs with the current configuration. Tracker-only CI
  does not prove the unintegrated child code. Recheck CI on the fully integrated
  tracker before any eventual merge to `main`.

## Handoff

Review each child against its immediate base. Keep the tracker draft until
all children are integrated and the full-feature checks pass. Do not delete
parent branches early. Publication does not authorize integration or merge.
