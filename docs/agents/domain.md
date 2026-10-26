# Domain docs

Use the repository's single-context domain documentation under `openspec/` when exploring or writing about Alethea's domain.

## Before exploring

- Read `openspec/CONTEXT.md` for the product and system principles.
- Read `openspec/UBIQUITOUS_LANGUAGE.md` and use its canonical terms.
- Read the relevant decisions under `openspec/adr/` for the area being changed.
- Read relevant active or archived SDD artifacts under `openspec/sdd/` when they describe prior requirements or implementation decisions.

If a document does not exist, proceed without inventing its contents. Surface a missing domain concept when it affects the design rather than silently introducing new terminology.

## Language and boundaries

The ubiquitous language document is authoritative for domain terms. In particular, distinguish patient-facing journaling from clinical sessions and professional-facing clinical consultation. Surface conflicts with existing ADRs or product principles instead of silently overriding them.
