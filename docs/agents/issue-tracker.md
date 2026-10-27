# Issue tracker: GitHub

Issues and specs for this repository live as GitHub Issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, and fetch labels when needed.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`.
- **Close an issue**: `gh issue close <number> --comment "..."`.

Infer the repository from its Git remote; `gh` does this automatically inside the clone.

## Pull requests as a triage surface

**No.** Pull requests are not used as a request surface for triage.

## Publishing specs

When a skill says to publish a spec to the issue tracker, create a GitHub issue. Apply the requested triage label when specified by that skill.
