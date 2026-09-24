# Proposal: E-O-R-C Functional Decomposition Draft Chain (#316)

**Issue:** #316 (sub-issue of spec #314) · **Blocks:** #319 (LiveView wiring) · **Exploration:** `openspec/sdd/eorc-draft-chain-316/exploration.md`
**Status:** decided — D1–D4 locked by the user; ready for `sdd-spec` + `sdd-design`.

## Intent

Clinicians today fill the eleven E-O-R-C fields of a functional analysis by hand, re-reading timeline evidence they already reviewed. #314 promises auto-drafting; nothing produces that draft. #316 delivers the missing generation unit — a pure, local-only LangChain chain that maps already-sanitized evidence into the exact eleven fields of `FunctionalAnalysisContent`, without diagnosing. It ships as an isolated, unit-testable module so the clinical guarantees are provable *before* #319 puts a button on it.

## Scope

### In Scope
- `AI.Chains.FunctionalAnalysisDraftChain` — `ChainBehaviour`, `:local`-only, pure `build_prompt/1` + `parse/1`, telemetry-wrapped `do_run/2` (skeleton cloned from `ClinicalHypothesisChain`).
- JSON schema over the 11 `FunctionalAnalysisContent.@fields` minus `previous_notes`.
- **(D1)** `AI.StructuredOutput` — new **opt-in** `unwrap_schema_echo/1` helper **and** the trailing-fence-strip fix inside `parse_json_response/1`.
- **(D1)** `test/alethea/ai/structured_output_test.exs` — new file; the module has no test coverage of its own today.
- **(D3)** Per-field lexical diagnostic/prescriptive scan in `parse/1`, reusing `HypothesisPolicy.diagnostic_patterns/0` and `prescriptive_patterns/0`; a matching field is blanked to `""`, the rest of the draft is untouched.
- **(D4)** Partial-tolerant `parse/1` contract: `{:ok, partial_map}` when ≥1 field parses, `{:error, :unparseable}` only when zero do.
- `LLMConfig`: `:functional_analysis_draft` in the closed `chain_name` type + one `chain_module/1` clause.
- Chain tests: clean / fenced / `properties`-echoed / malformed / partial responses, blanking cases, `:cloud`-absence and write-path-absence static scans.

### Out of Scope
- Any LiveView, button, worker, or wiring into `TargetBehaviorLive.Review` (→ #319).
- Non-destructive merge with existing clinician notes and `previous_notes` handling (→ #319).
- Mox mock registration in `config/test.exs` — no caller exists yet (→ #319).
- **(D2)** Migrating `PatternProposalChain` onto the new shared helper. Its code is **not touched** in this change; a separate follow-up ticket must be filed for the cleanup.
- Any change to `FunctionalAnalysisContent`, `Alethea.ClinicalRecord`, or persistence.
- Any new policy module — D3 is deliberately a plain function reuse, not a `HypothesisPolicy` sibling.

## Capabilities

### New Capabilities
- `functional-analysis-eorc-drafting`: how evidence becomes a proposed eleven-field E-O-R-C draft, what the chain may never do (diagnose, prescribe, persist), how diagnostic/prescriptive field text is blanked, and how partial or malformed model output is handled.

### Modified Capabilities
- None. `StructuredOutput` and `LLMConfig` gain additive surface; the trailing-fence fix only converts current failures into successes, so no existing requirement changes.

## Approach

Four additive units, no behavioral change to any shipped chain:

1. **Generate** — clone `ClinicalHypothesisChain` verbatim in shape: `:local`-only (decrypted PHI in the prompt), `StructuredOutput.with_schema/2` over an eleven-property object schema, pure `build_prompt/1`, pure `parse/1`, no `Repo` and no clinical-record write path. The system prompt carries the explicit no-diagnosis / no-prescription / no-factual-tone prohibitions (D3, layer 1).
2. **Normalize (D1)** — solve the SLM schema-echo (`{"properties" => {...real fields...}}`) once, generically, in a **new** `StructuredOutput.unwrap_schema_echo/1`; chains opt in by calling it on the decoded map, so `parse_json_response/1`'s contract for its four current callers is unchanged. Separately fix `parse_json_response/1` to strip trailing fences — a real live bug (`ClinicalHypothesisChain`, `ClinicalConsultationChain`, and `WeeklySummaryChain` all pass raw model text, so a complete fenced ```` ```json … ``` ```` block returns `{:error, :unparseable}` today) that maps directly onto #316's own "handles markdown backtick fences" criterion.
3. **Gate (D3)** — after extraction, scan each field's text against the already-public `HypothesisPolicy.diagnostic_patterns/0` / `prescriptive_patterns/0`. A match blanks **that one field** to `""`; siblings are unaffected. Per-field blanking (rather than whole-draft rejection) is possible precisely because the output is an editable form, not a single prose answer.
4. **Register** — one `chain_name` union member + one `chain_module/1` clause, mirroring `:consultation_hypothesis`.

Estimated ~280–380 authored changed lines (D3 adds ~15 lines plus a test table) — still within the 400-line budget as a single PR, with less headroom than before. `sdd-tasks` should confirm once prompt and schema text are drafted.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `lib/alethea/ai/chains/functional_analysis_draft_chain.ex` | New | The chain, including the D3 per-field scan and the D4 partial contract |
| `lib/alethea/ai/structured_output.ex` | Modified | D1: `unwrap_schema_echo/1` (new, opt-in) + trailing-fence fix |
| `lib/alethea/ai/llm_config.ex` | Modified | `:functional_analysis_draft` type + `chain_module/1` |
| `test/alethea/ai/chains/functional_analysis_draft_chain_test.exs` | New | Prompt / parser / blanking / partial / provider / structural tests |
| `test/alethea/ai/structured_output_test.exs` | New | D1 regression coverage for a module with no tests today |
| `lib/alethea/ai/chains/pattern_proposal_chain.ex` | **Untouched (D2)** | Follow-up ticket only |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `StructuredOutput` is shared by 4 parse callers and has **no test file today** | Medium | D1 makes `structured_output_test.exs` part of the deliverable and keeps `unwrap_schema_echo/1` opt-in, so `parse_json_response/1` stays contract-compatible |
| Trailing-fence fix silently changes behavior for existing chains | Medium | It only turns current failures into successes; assert all four callers' existing suites are unchanged and green |
| **D3 creates an `AI → ClinicalRecord.Rag.Consultation` dependency** that collides with the planned `refute source =~ "Alethea.ClinicalRecord"` static scan | **High** | **`sdd-design` must resolve**: either narrow the static scan to write paths (`Repo.`, `upsert_functional_analysis_content`) only, or extract the two pattern lists into a context-neutral pure module. Do not silently drop the scan |
| D3's lexical scan can be phrased around | Medium | Accepted; defense in depth (prompt + scan + clinician field-by-field review). Same limitation `HypothesisPolicy` documents |
| D3 blanking could remove a field the clinician wanted to see | Low | Blanking is per-field and reads as "not drafted" in the form; #319's merge never overwrites existing clinician text |
| D4 partial map could let a subtly-wrong field through beside good ones | Low | Accepted by decision: the draft is reviewed and edited field-by-field before it is ever persisted |
| Real phi4-mini output for an 11-field schema unproven by unit tests | Medium | Same gap as every existing chain (no live-endpoint tests in repo); cover synthetic shapes, validate manually at #319 |
| D2 leaves three fence/echo strategies coexisting | Low | Accepted only on condition the follow-up cleanup ticket is actually filed |

## Rollback Plan

Two new lib files' worth of change (one new module plus two additive edits) and two new test files. Revert = delete the chain and its test, drop the `:functional_analysis_draft` clauses from `LLMConfig`, and revert the two `StructuredOutput` additions (including the fence fix, which restores the prior — buggy — behavior). No migration, no persisted data, no caller in any shipped user path (by design — the caller is #319), so rollback cannot break a live flow.

## Dependencies

- None blocking. Branch `feat/316-eorc-draft-chain` already carries `FunctionalAnalysisContent`, `ClinicalHypothesisChain`, `HypothesisPolicy`, and `LLMConfig`.
- Blocks #319.
- Produces one follow-up ticket obligation (D2).

## Success Criteria

- [ ] `build_prompt/1` and `parse/1` are pure and tested without a live LLM endpoint.
- [ ] `parse/1` recovers all eleven fields from clean, fully-fenced, and `properties`-echoed responses.
- [ ] **(D4)** A response with 8 of 11 valid fields returns `{:ok, map}` containing exactly those 8 keys; a response with zero valid fields returns `{:error, :unparseable}`.
- [ ] **(D3)** A field whose text matches a diagnostic or prescriptive pattern is returned as `""`, and its sibling fields are returned unchanged.
- [ ] System prompt forbids diagnosis, prescription, and factual-tone clinical notes.
- [ ] **(D1)** `unwrap_schema_echo/1` and the trailing-fence fix are covered by `structured_output_test.exs`; all four existing `parse_json_response/1` callers' tests are unchanged and green.
- [ ] `supported_providers/0 == [:local]`; static scan proves the module source contains no `:cloud`.
- [ ] Static scan proves no `Repo.` and no `upsert_functional_analysis_content` in the chain source (scan scope reconciled with D3 — see Risks).
- [ ] `mix precommit` passes.

## Locked decisions (D1–D4)

All four were raised as open questions and answered by the user with the recommended option. They are binding inputs to `sdd-spec` and `sdd-design`.

### D1 — Shared parser fixes ship in this PR

Add a **new, opt-in** generic `unwrap_schema_echo/1` to `Alethea.AI.StructuredOutput`, and fix the trailing-fence-strip bug in `parse_json_response/1`. `parse_json_response/1`'s existing contract for its four current callers is **not** otherwise changed. `test/alethea/ai/structured_output_test.exs` is created as part of this deliverable.

*Rationale:* a narrow eleven-key match cloned from `PatternProposalChain` does not honestly scale — written properly it *becomes* the generic function, just trapped inside one chain and untestable in isolation, defeating the acceptance criterion that asks schema-echo handling to be provable. The fence bug is real and in-scope: `parse_json_response/1` anchors its regex at string start only, so the closing fence survives and `Jason.decode` fails for every caller that passes raw model text. None of the eleven field names is `"properties"`, so false-positive unwrapping has no real surface.

### D2 — `PatternProposalChain` is not migrated here

Its source is untouched in this change. A separate follow-up ticket is filed for the cleanup.

*Rationale:* the migration trades ~4 lines of removed duplication for a regression surface on a second shipped, tested chain that #316 does not require. *Standing obligation:* deferring leaves three fence/echo strategies coexisting, which is acceptable only because the follow-up ticket gets filed.

### D3 — "Without diagnosing" = prompt wording **plus** a per-field lexical scan that blanks

Reuse the already-public `HypothesisPolicy.diagnostic_patterns/0` and `prescriptive_patterns/0` as plain functions — **no new policy module**. If one E-O-R-C field's text matches a diagnostic or prescriptive pattern, that single field is set to `""`; every sibling field is returned unchanged.

*Rationale:* this exceeds #316's literal criteria on purpose. Unlike an ephemeral `Hypothesis` — gated by `HypothesisPolicy.evaluate/2`, its sole constructor — E-O-R-C text flows into `FunctionalAnalysisContent`, an encrypted, persisted, RAG-indexed clinical record, as soon as #319 wires it. The scan converts "never diagnoses" from an editorial promise into a testable structural guarantee, which is precisely the gap the #229 proposal named in `PatternProposalChain`. Per-field blanking (rather than rejecting the whole draft) is viable because the output is an editable form, not a single presented answer.

*Design-level follow-through required:* reusing `HypothesisPolicy` introduces an `Alethea.AI → Alethea.ClinicalRecord.Rag.Consultation` reference, which collides with the precedent static scan — `test/alethea/ai/chains/clinical_hypothesis_chain_test.exs:198` asserts `refute source =~ "Alethea.ClinicalRecord"` as a "superset guard" over the write-path refutes on lines 190-194. `sdd-design` must pick one: narrow the scan to write paths only (`Repo.`, `upsert_functional_analysis_content`), or lift the two pattern lists into a context-neutral pure module. The scan must not simply be dropped.

### D4 — Partial parse returns `{:ok, partial_map}`

`parse/1` returns `{:ok, partial_map}` whenever **≥1** of the eleven fields parses cleanly. Missing or malformed individual fields are **left absent from the map**, letting `FunctionalAnalysisContent.new/1`'s existing `""` defaulting handle them. `{:error, :unparseable}` is returned **only** when zero fields parse.

*Rationale:* a deliberate divergence from `ClinicalHypothesisChain`'s and `ClinicalConsultationChain`'s fail-loud precedent. Those two fail loud because their output is *presented as an answer*, where a blank reads as "nothing found" — a false clinical negative. An E-O-R-C draft is a pre-filled form the clinician reads and edits field by field; an empty field there reads as "not drafted", which is honest and matches the form's own default. Discarding eight good fields because three were malformed is strictly worse for the clinician.

*Consequence for #319:* because absent fields are omitted rather than emitted as `""`, the returned map's **key set is itself the record of which fields the AI drafted**. #319 can use it to visually distinguish AI-drafted fields from untouched ones with no extra return value. Note this also means D3-blanked fields are present with value `""` — distinguishable from never-parsed fields, which are absent entirely.
