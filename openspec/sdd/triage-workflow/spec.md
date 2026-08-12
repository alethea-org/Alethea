# Delta Spec — triage-workflow

**Change:** triage-workflow (PR #152) | **Store:** hybrid
**Baseline:** no prior `openspec/specs/{domain}/spec.md` exists for `github-workflow` — requirements below are ADDED against current repo state (no labels assigned, no slash commands, no rotation).

## Domain: issue-lifecycle (triage workflow)

### ADDED Requirements

#### Requirement: New issue gets `status:needs-triage` automatically

On `issues.opened`, the system MUST add the label `status:needs-triage` to the new issue. The action MUST be idempotent (no duplicate label error on retries).

##### Scenario: Bug template opens new issue
- GIVEN a contributor fills `.github/ISSUE_TEMPLATE/bug.yml` and submits
- WHEN the issue is created with default labels `bug, status:needs-triage`
- THEN `status:needs-triage` is present (already in template)
- AND the bot does NOT add it again (idempotent)

##### Scenario: Issue opened without template (manual)
- GIVEN a contributor opens a blank issue
- WHEN the `issues.opened` event fires
- THEN the bot adds `status:needs-triage` automatically

#### Requirement: `/claim` slash command assigns to author

When a user comments exactly `/claim` on an issue, the system MUST assign the comment author if they are a member of the org and the issue has no current assignees.

##### Scenario: Member claims an unassigned issue
- GIVEN issue #N has no assignees
- AND `@dev` is a MEMBER or OWNER of the org
- WHEN `@dev` comments `/claim` on #N
- THEN `@dev` becomes the sole assignee
- AND `status:claimed` is added
- AND `status:needs-triage` is removed
- AND the bot comments "✅ Issue tomada por @dev. Lock activo."

##### Scenario: Non-member tries to claim
- GIVEN a contributor without MEMBER/OWNER association comments `/claim`
- WHEN the bot processes the comment
- THEN the bot comments "🔒 Solo miembros de la org pueden /claim issues."
- AND no assignment change happens

##### Scenario: Claim an already-claimed issue
- GIVEN issue #N has assignee `@other`
- WHEN any user comments `/claim` on #N
- THEN the bot comments "❌ Esta issue ya está tomada por @other. Pedile que la libere con /release."
- AND no assignment change happens

##### Scenario: Claim a wayfinder:prototype or wayfinder:grilling
- GIVEN issue #N has label `wayfinder:prototype` or `wayfinder:grilling`
- WHEN any user comments `/claim` on #N
- THEN the bot comments "🚫 Esta issue es wayfinder:prototype/grilling. Solo el PO de la semana la puede manejar."
- AND no assignment change happens

#### Requirement: `/release` slash command clears assignment

When the current assignee comments `/release`, the system MUST remove them as assignee and reset the labels.

##### Scenario: Assignee releases their own issue
- GIVEN issue #N is assigned to `@dev`
- WHEN `@dev` comments `/release`
- THEN `@dev` is removed from assignees
- AND `status:claimed` is removed
- AND `status:needs-triage` is added
- AND the bot comments "🔓 @dev liberó esta issue. Vuelve a status:needs-triage."

##### Scenario: Non-assignee tries to release
- GIVEN issue #N is assigned to `@other`
- WHEN `@dev` (not the assignee) comments `/release`
- THEN the bot comments "🔒 Solo el assignee actual (@other) puede liberar esta issue."
- AND no assignment change happens

##### Scenario: Release on unassigned issue
- GIVEN issue #N has no assignees
- WHEN any user comments `/release`
- THEN the bot comments "ℹ️ Esta issue no tiene assignee. No hay nada que liberar."
- AND no state change happens

#### Requirement: `/blocked <razón>` slash command

The current assignee MUST be able to block their own issue with a reason.

##### Scenario: Assignee blocks their issue
- GIVEN issue #N is assigned to `@dev`
- WHEN `@dev` comments `/blocked esperando input de @other sobre KEK rotation`
- THEN label `status:blocked` is added
- AND the bot comments "🛑 Bloqueada por @dev: esperando input de @other sobre KEK rotation"

##### Scenario: Non-assignee tries to block
- GIVEN issue #N is assigned to `@other`
- WHEN `@dev` comments `/blocked <cualquier razón>`
- THEN the bot comments "🔒 Solo el assignee puede bloquear su propia issue."
- AND no label change happens

#### Requirement: `/unblocked` slash command

The current assignee MUST be able to unblock their own issue.

##### Scenario: Assignee unblocks their issue
- GIVEN issue #N is assigned to `@dev` AND has `status:blocked`
- WHEN `@dev` comments `/unblocked`
- THEN label `status:blocked` is removed
- AND `status:claimed` is added back
- AND the bot comments "🔄 @dev desbloqueó la issue. Vuelve a status:claimed."

##### Scenario: Unblock on non-blocked issue
- GIVEN issue #N does not have `status:blocked`
- WHEN any user comments `/unblocked`
- THEN the bot comments "ℹ️ Esta issue no está bloqueada."
- AND no state change happens

#### Requirement: Hard lock on assignee modifications

When the `assignees` field is edited, the system MUST revert the change unless the actor is the current assignee or the active PO of the week.

##### Scenario: Non-authorized user changes assignees
- GIVEN issue #N is assigned to `@dev`
- AND the current PO is `@po`
- WHEN `@other` edits the issue and changes assignees
- THEN the bot reverts the assignees to the previous state
- AND the bot comments "🔒 Asignación protegida. Solo el assignee actual o el PO pueden modificar esto."

##### Scenario: PO reasigns manually
- GIVEN issue #N is assigned to `@dev`
- AND the current PO is `@po`
- WHEN `@po` edits the issue and reasigns to `@other`
- THEN the bot comments "🔧 PO de la semana (@po) reasignó esta issue."
- AND the change is preserved

##### Scenario: Assignee reasigns to self
- GIVEN issue #N is assigned to `@dev`
- WHEN `@dev` re-asigna a sí mismo (cambio sin efecto neto)
- THEN the bot does nothing (no lock enforcement needed)

#### Requirement: Cap of one assignee per issue

When the `assignees` field is edited and has more than one assignee, the system MUST keep only the first assignee.

##### Scenario: Multiple assignees after manual edit
- GIVEN issue #N has assignees `[@dev1, @dev2]`
- WHEN the bot detects the multi-assignee state
- THEN only `@dev1` remains as assignee
- AND the bot comments "⚠️ Regla 'una persona por issue'. Se detectó más de un assignee..."

#### Requirement: `status:done` set on PR merge closing issue

When a PR is merged and closes an issue, the system MUST set the issue's status label to `status:done`.

##### Scenario: PR with `Closes #N` is merged
- GIVEN issue #N has `status:claimed`
- WHEN a PR with body `Closes #N` is merged
- THEN issue #N's `status:claimed` is removed
- AND `status:done` is added
- AND the bot comments "✅ Issue cerrada vía PR #Y. status:done (sello histórico)."

#### Requirement: PR soft check on ready for review

When a PR transitions from draft to ready for review and references a closed issue assigned to someone other than the PR author, the system MUST add a non-blocking comment.

##### Scenario: PR ready, author != assignee
- GIVEN issue #N is assigned to `@dev`
- WHEN `@other` opens a PR with `Closes #N` and marks it ready for review
- THEN the bot comments on the PR: "ℹ️ Esta PR cierra #N (asignada a @dev) pero el autor es @other. ¿Intencional?"

##### Scenario: PR ready, author == assignee
- GIVEN issue #N is assigned to `@dev`
- WHEN `@dev` opens a PR with `Closes #N` and marks it ready for review
- THEN the bot does NOT comment (everything consistent)

#### Requirement: Weekly PO rotation

Every Monday at 10:00 ART, the system MUST rotate the PO to the next user in `.github/ROTA.yml` and update the pinned Triage rota issue (#150).

##### Scenario: Scheduled rotation triggers
- GIVEN `.github/ROTA.yml` has `current_po: "@vicenzogiordana"` and `order: [vicenzogiordana, huajar, teofurlan, eveernst, demianfrick]`
- WHEN the cron `0 13 * * 1` fires (Monday 10:00 ART)
- THEN `.github/ROTA.yml` is updated to `current_po: "@huajar"` with `last_rotated: <today>`
- AND the change is committed and pushed to `main`
- AND issue #150 body is updated to reflect the new PO
- AND a comment is posted on #150: "🔄 Semana N: turno de @huajar."

##### Scenario: First rotation (no current_po)
- GIVEN `.github/ROTA.yml` has no `current_po` (first run)
- WHEN the workflow fires
- THEN `current_po` becomes `order[0]` (`vicenzogiordana`)

##### Scenario: Manual reordering via PR
- GIVEN the team edits `.github/ROTA.yml` with a PR that changes the `order` array
- WHEN the PR is merged
- THEN the next scheduled rotation follows the new order
