# Issue #442 — PR delivery chain
Goal: publish the verified trigger-management feature as a draft tracker and three coherent child PRs.
Strategy: feature-branch-chain; no merge, CI changes, protected-label exceptions or production migration authorized.
Source: `feat/442-trigger-management` at `9603758c53510857b5deb65bcfd4c0d60e2980d4`; default branch `main` at `c2d21ea8bba6e921eec4016a721068aa36902c29`.

## Specs
S1. "hagamos PR"
S2. "Sí, publicar en alethea-org/Alethea"
S3. "Cerrar al mergear el tracker (recomendado)"
S4. "Sí, agregar status:approved a #442"

## Tasks
D1 | S1-S3 | inline delivery preparation | in_progress | Build core (including R1 correction), UI (including icon correction), then dashboard slices; original branch untouched.
D2 | S1-S2 | local functional checks | pending | Verify each slice and final Git-tree equality with the source above.
D3 | S1-S4 | authorized GitHub publication | pending | Draft tracker uses Closes #442; child PRs use Refs #442 and one type:feature label.
D4 | S1-S3 | target-bound CI inspection | pending | Report actual checks; child bases do not trigger the current main-only Elixir CI.

## Log
L1. User: "hagamos PR".
L2. Destination github.com/alethea-org/Alethea and the current GitHub CLI session were explicitly authorized for reads, new-branch push and PR creation. Actor @vicenzogiordana is ADMIN; only status:approved was added to #442 with explicit authorization.
L3. The verified source passed mix precommit (2590 checks, 5 skips). Native review approved corrected code commit 8f2d70e and exact acknowledgement burned its authority; later source changes are passive task-documentation only. Slice-local checks remain pending.
L4. Keep this tracker draft/no-merge until child PRs are reviewed and integrated in order. This bootstrap file is removed by the final child once the canonical feature task document is restored; PR bodies retain the dependency graph.
L5. The 400-line review budget is advisory. The three behavior units cannot honestly fit it without separating tests from behavior; report actual counts rather than deleting coverage or inventing a size exception.
