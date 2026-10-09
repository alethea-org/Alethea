# Archive Report: running-summary-394 (#394)

**Archived on 2026-10-09; not yet merged to main.**

## Summary

Running summary for the Telegram journaling reply path (issue #394). Delivered as a chain of five stacked PRs (S0-S4) plus a CI-only draft PR. Each PR says "Part of #394"; none says "Closes". #394 closes when the chain lands on main.

Final-state facts at close (ranked per the Final-State Authority section; the launch prompt is the most recent account):

- Verification: second pass on e2510ee, verdict PASS WITH WARNINGS, 0 CRITICAL, REQ-01..REQ-22 and 57 scenarios covered (per `verify-report.md`, at verification time).
- W-1 (8 Windows-only `Alethea.ReleaseTest` failures): resolved by green Linux CI on the CI-only draft PR #417 (launch prompt, green as of e2510ee: Format check, Release image, Test).
- W-A (tasks.md missing S4-provider-pin / S4-cloud-gate rows and REQ-22 coverage line): fixed in caa0ccf (`tasks.md` +3 lines). Archived `tasks.md` has 46 checked and 0 unchecked tasks.
- W-B (`Scenario: Professional change fails closed` misattributed under REQ-22): fixed in caa0ccf. Verified in archived `spec.md`: the scenario is at line 341, above `### REQ-22` at line 346.
- S-1 (superseded snippet at `design.md:130`): intentionally kept, marked "superseded by A5".

## Artifacts

Archived folder: `openspec/sdd/archive/2026-10-09-running-summary-394/`

| File | Status |
|------|--------|
| `proposal.md` | archived |
| `spec.md` | archived (record of REQ-01..REQ-22; not merged into main specs) |
| `design.md` | archived |
| `exploration.md` | archived |
| `tasks.md` | archived (46/46 checked) |
| `apply-progress.md` | archived (intermediate snapshot) |
| `verify-report.md` | archived (intermediate snapshot, second pass at e2510ee) |
| `archive-report.md` | this file |

Main specs: `openspec/specs/` does not exist and no previous archive created it. No delta merge was performed and `openspec/specs/` was not created. The archived `spec.md` remains the record of behavior.

Observation IDs: not applicable. Artifact store is `openspec`; artifacts were read from the filesystem, not Engram.

## Delivery

| PR | Branch | Base | Status | Label |
|----|--------|------|--------|-------|
| #410 (S0) | `feat/394-protected-running-summary` | main | open | — |
| #412 (S1) | (stacked) | S0 | open | `size:exception` |
| #414 (S2) | (stacked) | S1 | open | `size:exception` |
| #416 (S3) | (stacked) | S2 | open | `size:exception` |
| #418 (S4) | `feat/394-s4-integration` | S3 | open | `size:exception` |
| #417 | `ci/394-chain` | main | draft, CI-only | — |

- Whole stack rebased on main `72a2a2f` (includes #391 burst replies and #402 Fly/prod/AI-degradation).
- CI runs only on PRs to main, hence the CI-only draft PR #417 (green as of e2510ee).
- Remaining: land the chain to main (merge order or land-to-main PR), close #417, then #394 closes via the landing.

## Verification Outcome

Per `verify-report.md` (second pass, e2510ee, at verification time):

- Build: `mix compile --warnings-as-errors` exit 0.
- Tests excluding `release_test.exs`: 6 doctests, 1783 tests, 0 failures.
- Full requested suite: 1803 tests, 8 failures, all in `Alethea.ReleaseTest` on Windows (POSIX sh scripts under `System.cmd`). Pre-existing platform issue; file untouched by the chain. Resolved by green Linux CI per final-state facts.
- Requirements 22/22, scenarios 57/57 covered by passing tests (REQ-19 static).

Test counts above are from the verify pass and were not re-run at archive time.

## Decisions

| ID | Decision |
|----|----------|
| D1 | Crisis exchanges included in the summary. Exclusion tracked in #399. |
| D2 | Interim crisis-copy mitigation applied. |
| D3 | Summary format decided (format/cap/guard, REQ-04). |
| D4 | Name: "Resumen conversacional". |
| A5 | Single system message. Smoke gate with two runs; run 2 has no log on disk (noted as non-reproducible). |
| Pin | Provider pinned to `:local` per `docs/deployment/fly-neon.md` policy (`config/runtime.exs`). |
| REQ-22 | Cloud gate: no summary is sent to a hosted model. Disabled unless a local endpoint is configured AND the guided chain provider is `:local`. |

## Known Limitations and Follow-ups

- #399: crisis exchange exclusion from the summary (follow-up to D1).
- Short crisis copy (under 20 characters) is not matched by the crisis-copy rejection (accepted limitation, REQ-05).
- Pre-existing: burst path performs multiple DEK unwraps. Not introduced by this change.
- Out-of-scope observations recorded in `apply-progress.md` (S4) and the #418 body, not filed as issues by user decision:
  - journaling prompt recall
  - two-question replies at temperature 0.7
  - tú vs voseo register
  - docker-compose `phi-4-mini` hyphen
- Verify suggestions S-2 through S-6 (non-reproducible smoke run 2 log; tasks forecast lacks actuals; REQ-14 success-path log cleanliness; `config/runtime.exs` dev block untested; `RunningSummaryWorker` logged the patient UUID on failure at `running_summary_worker.ex:85` — **fixed after archive in 50fe7ac**: the warning now carries the reason only, with a test asserting the patient id is absent). Their status after e2510ee is not recorded in the final-state facts; treat as open unless the PRs say otherwise.

## Archive Integrity Note

The mechanical move used `git mv` (7 rename entries, 100% similarity in the index). No pre-move filesystem snapshot was taken, so the `diff -r` readback was replaced by a git object-level readback, which is stronger: for each of the 7 files, the blob id at the old path in `HEAD` (caa0ccf) equals the blob id at the new path in the index — identical content, byte for byte:

| File | Blob (old path = new path) |
|---|---|
| apply-progress.md | 9f99d62873 |
| design.md | 5280b58f34 |
| exploration.md | e0fd6a6396 |
| proposal.md | 8e28471491 |
| spec.md | 49e7ca7841 |
| tasks.md | 35566b2fb5 |
| verify-report.md | 02e0fc9325 |

The only differences a working-tree `diff -r` showed were CRLF vs LF line endings from `core.autocrlf` on Windows, not content. Integrity: **verified (7/7 identical)**.
