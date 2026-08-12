# Tasks — triage-workflow

**Change:** triage-workflow (PR #152) | **Store:** hybrid
**Mode:** Strict TDD — every task is RED (failing test first) → GREEN (minimum code to pass) → REFACTOR (cleanup, still green).
**Test runner:** workflows are tested by GitHub Actions themselves; manual smoke tests are listed in §Verification.

**Inputs:** `spec.md`, `design.md`.

## Delivery grouping

This change ships as **one PR (#152)** with **3 logical commits**:

- **Commit 1 — docs**: ADR + 5 SDD files (proposal, exploration, spec, design, tasks).
- **Commit 2 — feat(github)**: extend `triage.yml` (4 new jobs + handlers), update `setup-labels.yml`, update `CONTRIBUTING.md`.
- **Commit 3 — docs(github)**: create `QUICKSTART.md`, update `README.md`.

Commits are atomic and reversible independently.

---

## Commit 1 — docs (ADR + SDD)

### T1.1 — Write `openspec/adr/009-triage-workflow.md`

Follows the format of existing ADRs (001–008). Captures the decision, the 5 alternatives considered, and the consequences.

### T1.2 — Write `openspec/sdd/triage-workflow/{proposal,exploration,spec,design,tasks}.md`

Follows the format of `openspec/sdd/telegram-safe-path-ai-reply/`. Five files in the canonical SDD order: proposal → exploration → spec → design → tasks.

**Strict TDD note**: docs are not code. "Test" is: a teammate can read each doc and answer "what does this say?" without ambiguity. Verify by review.

### T1.3 — Cross-link between ADR and SDD

Add links from `009-triage-workflow.md` to the 5 SDD files. Add links from each SDD file to the ADR.

**Commit message**: `docs(adr): 009 triage-workflow + SDD completo`

---

## Commit 2 — feat(github) extension

### T2.1 — Add `pr-merged-status-done` job

**Satisfies:** "status:done set on PR merge closing issue" (spec).

**File:** `.github/workflows/triage.yml`

**Steps:**
- Add a new job to the existing `triage.yml`.
- Trigger: `pull_request: { types: [closed] }`.
- Condition: `github.event.pull_request.merged == true`.
- Permissions: `issues: write`.
- Logic:
  - Parse PR body for `closes #N`, `fixes #N`, `resolves #N` (case-insensitive).
  - For each referenced issue: read labels. If has `status:claimed` → swap to `status:done`, comment.

**Test**: open a PR with `Closes #N` where #N has `status:claimed`. Merge it. Verify status changes.

### T2.2 — Add `/blocked` and `/unblocked` handlers

**Satisfies:** "/blocked slash command", "/unblocked slash command" (spec).

**File:** `.github/workflows/triage.yml`

**Steps:**
- Extend the existing `handle-slash-command` job with two new branches.
- `/blocked <razón>`:
  - If author == current assignee → add `status:blocked`, comment with reason.
  - Else → comment "🔒 Solo el assignee puede bloquear..."
- `/unblocked`:
  - If author == current assignee AND issue has `status:blocked` → remove `status:blocked`, add `status:claimed`.
  - Else → comment "🔒 Solo el assignee puede desbloquear..." or "ℹ️ No está bloqueada."

**Test**: claim an issue → comment `/blocked falta X` → verify label. Then `/unblocked` → verify back to claimed.

### T2.3 — Add MEMBER/OWNER check + wayfinder exemption to `/claim`

**Satisfies:** "Non-member tries to claim", "Claim a wayfinder:prototype or wayfinder:grilling" (spec).

**File:** `.github/workflows/triage.yml`

**Steps:**
- Modify the `/claim` branch of `handle-slash-command`.
- Add early check: `comment.author_association in ['MEMBER', 'OWNER']`. If not → reject with explicit message.
- Add early check: issue has label `wayfinder:prototype` or `wayfinder:grilling`. If yes → reject with explicit message.

**Test**: try `/claim` from a non-member account (or fork). Verify rejection. Try `/claim` on a wayfinder:prototype issue. Verify rejection.

### T2.4 — Add `pr-soft-check` job

**Satisfies:** "PR soft check on ready for review" (spec).

**File:** `.github/workflows/triage.yml`

**Steps:**
- New job. Trigger: `pull_request: { types: [ready_for_review] }`.
- Permissions: `issues: read, pull-requests: write`.
- Logic:
  - Parse PR body for closing patterns.
  - For each referenced issue: get assignee. If `assignee != null && assignee != pr_author && assignee != current_po` → comment on PR.

**Test**: open a draft PR with `Closes #N` where #N is assigned to someone else. Mark ready. Verify the soft comment.

### T2.5 — Update `setup-labels.yml` to include `status:done`

**Satisfies:** consistency with the new label introduced in T2.1.

**File:** `.github/workflows/setup-labels.yml`

**Steps:**
- Add `{ name: "status:done", color: "6f42c1", description: "Cerrada via PR mergeada - sello historico" }` to the labels array.

### T2.6 — Update `CONTRIBUTING.md`

**Satisfies:** documentation consistency with the workflow changes.

**File:** `.github/CONTRIBUTING.md`

**Steps:**
- Add `/blocked` and `/unblocked` to "Reglas duras" section.
- Update "Cómo funciona en la práctica" with the new commands.
- Add `status:done` to the vocabulary section.
- Document the wayfinder exemption.
- Document the MEMBER/OWNER restriction on `/claim`.

**Commit message**: `feat(github): status:done + wayfinder exemption + blocked/unblocked + member-only`

---

## Commit 3 — docs(github) QUICKSTART

### T3.1 — Create `.github/QUICKSTART.md`

**Satisfies:** "Quickstart for human reader" (new requirement raised during design).

**File:** `.github/QUICKSTART.md`

**Structure:**
- §1 — Overview (1 pantalla): Mermaid flowchart + table of 5 commands.
- §2 — Escenarios:
  - §2.1 — Tomar y terminar una issue (narrativa + tabla de comandos)
  - §2.2 — Una semana como PO (3 mini-escenarios)
  - §2.3 — Issue bloqueada (Mermaid state diagram)
- §3 — Para evaluadores: actor Mermaid + tabla pregunta-comando-output.
- §4 — Anti-patrones (5 confirmados).
- §5 — Ver también (links cruzados).

**Target length**: ~300 líneas.

### T3.2 — Update `README.md` with Onboarding section

**File:** `README.md`

**Steps:**
- Add a section near the top (right after the title) titled "🚀 Onboarding".
- Body: short paragraph + link to `.github/QUICKSTART.md`.

**Commit message**: `docs(github): QUICKSTART + actualizar CONTRIBUTING y README`

---

## Verification (post-merge)

Manual smoke tests, run in order:

1. **Auto-triage**: open a blank issue → verify `status:needs-triage` added.
2. **`/claim` happy path**: member comments `/claim` → verify assigned + `status:claimed` + comment.
3. **`/claim` blocked for non-member**: from a fork, try `/claim` → verify rejection message.
4. **`/claim` blocked for wayfinder**: create issue with `wayfinder:prototype` → try `/claim` → verify rejection.
5. **`/claim` blocked for taken**: try `/claim` on a claimed issue → verify "ya tomada".
6. **`/release` happy path**: assignee comments `/release` → verify unassigned + relabeled.
7. **`/release` blocked for non-assignee**: another user tries `/release` → verify rejection.
8. **`/blocked` happy path**: assignee comments `/blocked razón X` → verify `status:blocked` + comment with reason.
9. **`/blocked` blocked for non-assignee**: another user tries → verify rejection.
10. **`/unblocked` happy path**: assignee comments `/unblocked` → verify back to `status:claimed`.
11. **Hard lock**: another user edits assignees → verify revert + lock comment.
12. **PO override**: PO edits assignees → verify comment "🔧 PO reasignó".
13. **Cap one assignee**: assign issue to two people via API → verify only first remains.
14. **PR soft check**: open draft PR with `Closes #N` (where author ≠ assignee) → mark ready → verify comment.
15. **PR status:done**: merge PR with `Closes #N` (where #N has `status:claimed`) → verify `status:done` + comment.
16. **Rotation**: trigger `rotate.yml` via workflow_dispatch → verify ROTA.yml updated + issue #150 updated + comment.

All 16 checks should pass before declaring the PR production-ready.

---

## Out of scope (separate PRs)

- `CODEOWNERS` per area
- Weekly metrics summary
- Stale-issues workflow
- Slack/Discord notifications
- Auto-claim UI button
