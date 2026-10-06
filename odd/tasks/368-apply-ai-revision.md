# Issue #368 — Apply reviewed AI revision

## Intent and scope
Explicit whole-proposal Apply writes only the mutable E-O-R-C working draft. Recheck authorization, legal deletion, cited evidence and preview-start baseline atomically. Rejection preserves the prior draft; accepted edits survive confirmed save/reload. Discard, duplicate Apply and late async must never save unaccepted AI text. Separate historical version registration remains unchanged.

## Authorization and delivery
Base d0cb9323f3b2f6914910daee08f85d83245a0d55 includes #367/PR #384. User approved fast-forward main, feature branch, local work-unit commits and stacked-to-main organization (main verified default). No push, PR or merge authorized. Single writer.
User approved Docker Desktop and docker compose up -d db; existing PostgreSQL16 container restored twice, no data deletion/config edits. Current availability not assumed indefinitely.
Original forecast270–430 exceeded. One coherent slicing pass: domain1004 lines, integration1442 lines =2446 authored source/test changes. Keep behavior with tests; do not reduce coverage/readability for budget. Both potential PRs remain oversized; reviewer-size acceptance needed before publication, no generic project label assumed.

## Tasks and commits
- [x] T1: Atomic domain Apply and tests; independently verified; native review approved and acknowledged. Commit8d6a0db63aa5ef2b570e29cc077b71064ea6df53 on feat/368-ai-apply-domain. Rollback scope: clinical_record.ex + functional_analysis_proposal_test.exs.
- [x] B1: Diagnose environment and initial authorization recovery; fail-open baseline/citation findings corrected in T1.
- [x] T2: LiveView acceptance lifecycle implemented and independently verified; commit7b99910d06e3839cf70a51a3d27f81c19b913fce on feat/368-apply-ai-revision, parent8d6a0db. Native review approved and acknowledged. Rollback scope: review.ex + review_test.exs.
- [x] B2: Resume dirty clinician autosave after discard/cancel/error; tests and independent checks passed; same approved and acknowledged integration commit7b99910.
- [x] B3: Restore previously authorized Docker/db after recurrent unavailable engine; healthy/pg_isready confirmed; reason for shutdown unknown.
- [x] T3: Scoped functional checks and native review of both work-unit commits completed; final integration boundary7b99910. This passive tracking document records closure; no publication.
Routes: delegated workers for multi-file/preparation work, delegated verifiers for commands/independent checks, parent mechanical Git/task updates and exact native facade orchestration.

## Contract and checks
Canonical apply_functional_analysis_ai_proposal/5 requires explicit draft_baseline (:no_draft or positive lock version) and cited_evidence_ids (UUID list, [] intentional empty); malformed/omitted inputs fail closed. Exact replay idempotent; history isolated. LiveView captures generation-start baseline, restores original clinician values on rejection and resumes only dirty accepted clinician values through ordinary guarded autosave.
Observed T1 RED: six omission/malformed-input assertions; GREEN independent32 domain tests. T2 RED: rejected conflict retained proposal text/no-draft concurrent creation; GREEN185 combined tests. B2 RED: persisted initial text rather than clinician edit during generation; GREEN selected tests and157 LiveView tests. Final independent combined189 tests/0 failures; compile warnings-as-errors and scoped4-file format pass.
Full MIX_ENV=test mix test:6 doctests,1812 tests,0 failures,5 skipped (513.2s). Skip reasons not supplied. mix deps.unlock --check-unused:exit0/no lock mutation. Warnings outside changed paths: retry_test:42 unused variable; rag/citation_test:56 type warning; deprecated evidence-helper test fixtures. No physical browser tools/checks.
Literal mix precommit skipped by explicit scoped_checks consent: its global format would change352 unrelated files. Compilation, read-only dependency checks, changed-file format and complete suite run separately. No unrelated normalization performed. Early PostgreSQL failures were environmental, not behavioral RED; compile alone never counted as GREEN.

## Native review evidence
Domain immutable base d0cb932 ->8d6a0db: lineage review-e45d3692d055d3cf, medium tier, reliability lens. Final approved acknowledgement returned authority burned, consumed revision sha256:c0c915890156b3ffda8a0fe47b3c87020b218140d4da2fee4e74f9d8b448feae. No post-burn STATUS.
Five informational nonblocking followups only: R3-cast-uuid-list-reverses; R3-concurrent-test-nondeterminism; R3-double-wrapped-rollback; R3-missing-same-baseline-different-content-test; R3-no-lock-on-draft-read. No correction route; never reopen approved domain for these advisories.
Integration immutable base8d6a0db ->7b99910: lineage review-31482c2f5bfc4f6b, medium tier, reliability lens. Final approved acknowledgement returned authority burned, consumed revision sha256:c7a370fd7d453d84a85387b3087bdc3f78d08f2d23f180b632bcf6f27fc8e5ff. No post-burn STATUS. Four informational nonblocking followups only: R3-autosave-guard-ordering; R3-draft-baseline-fallback; R3-evidence-ids-coercion; R3-legally-deleted-timestamp. Both receipts stand; no correction route or code changes from either review. Combined source is exactly the previously verified source, not a newly modified candidate.
Earlier native preflight needed exact committed selector/untracked declaration; no lineage created on mismatch. Managed-assets stop resolved by exact offered sync (host-managed files only). Earlier timed-out verifier later recovered actual185-pass evidence; warning causality unknown. No safety verdict inferred from failed/unknown tools.

## Continuity and next step
Local locator odd/tasks/368-apply-ai-revision.md; full Engram mirror topic odd/368-apply-ai-revision/tasks via cwd-bound save (explicit-project routing failed). Read/reconcile both on resume.
Both native reviews complete and acknowledged. Local stack main -> feat/368-ai-apply-domain (8d6a0db) -> feat/368-apply-ai-revision (7b99910 plus passive tracking documentation). Nine nonblocking advisories are separate future work, not accepted scope expansion. No browser check; five skipped tests and existing test warnings remain disclosed. Publishing requires a new user decision and agreement on oversized slice review. No push/PR/merge.
