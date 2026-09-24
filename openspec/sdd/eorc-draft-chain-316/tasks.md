# Tasks: E-O-R-C Functional Decomposition Draft Chain (#316)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~271 / PR2 ~414 / Total ~685 |
| 400-line budget risk | PR1: Low · PR2: Low-Medium (~3% over if untrimmed) |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 (PR2 bases on PR1's branch) |
| Delivery strategy | ask-on-risk (resolved: feature-branch-chain) |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No (user already resolved chain strategy)
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | PR | Focused test command | Harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | D1 fixes + AD1 catalog extraction | PR1 (base: main) | `mix test test/alethea/ai/structured_output_test.exs test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` | N/A — pure functions, no live endpoint | revert 5 files; no caller depends on it yet |
| 2 | FunctionalAnalysisDraftChain + wiring | PR2 (base: PR1 branch) | `mix test test/alethea/ai/chains/functional_analysis_draft_chain_test.exs` | N/A — no shipped caller (#319 not yet wired) | delete chain+test, drop 2 LLMConfig clauses, drop Mox lines |

## PR1: Shared Foundations (base: main)

### Phase 1 — StructuredOutput (D1)
- [x] 1.1 RED `test/alethea/ai/structured_output_test.exs`: `unwrap_schema_echo/1` wrapped/unwrapped/double-wrapped/non-map-`properties`/empty-map cases (spec: unwraps-or-passes-through).
- [x] 1.2 RED same file: `parse_json_response/1` trailing-only, both-fences, `json`-tag, bare-fence, whitespace-padded, unfenced-unchanged, invalid-json, non-object cases (spec: fence stripping + contract-unchanged scenarios).
- [x] 1.3 GREEN `lib/alethea/ai/structured_output.ex`: add `unwrap_schema_echo/1`; fix `parse_json_response/1` per design's before/after regex.
- [x] 1.4 Run existing suites for `ClinicalHypothesisChain`, `ClinicalConsultationChain`, `WeeklySummaryChain`, `PatternProposalChain` unmodified — confirm all green (spec: "all four callers' suites remain green").

### Phase 2 — ClinicalSafetyPatterns extraction (AD1)
- [x] 2.1 RED `test/alethea/ai/clinical_safety_patterns_test.exs`: 9+9 regex order identity, `normalize/1` accent/case/whitespace folding.
- [x] 2.2 GREEN create `lib/alethea/ai/clinical_safety_patterns.ex`: move `@diagnostic_patterns`/`@prescriptive_patterns`/`normalize/1` verbatim from `hypothesis_policy.ex`.
- [x] 2.3 GREEN edit `lib/alethea/clinical_record/rag/consultation/hypothesis_policy.ex`: replace bodies with `defdelegate` (2 accessors) + `defp normalize/1` delegating call; keep list order/arity/names unchanged.
- [x] 2.4 Run `hypothesis_policy_test.exs` UNMODIFIED — must stay green (regression proof for AD1, lines 161-223, 289-291). Verified zero diff (`git diff --stat`) and 91/91 passed.
- [x] 2.5 Add delegation-parity assertion in 2.1: `HypothesisPolicy.diagnostic_patterns() == ClinicalSafetyPatterns.diagnostic_patterns()` (+ prescriptive). **Deviation**: raw `==` on `Regex.t()` is never true across independent evaluations (opaque `re_pattern` field, no structural equality — confirmed even self-calls of the same accessor twice are `==`-unequal). Implemented parity via `{source, opts}` pair comparison instead, which fully determines matching behavior.

### Phase 3 — Verify
- [x] 3.1 Focused test suites green; `mix compile --warnings-as-errors --force` and `mix format --check-formatted` clean (full `mix precommit`/full suite deferred to orchestrator per protocol). Diff confirmed to exclude `lib/alethea_web/`, `functional_analysis_content.ex`, `clinical_record.ex`, `pattern_proposal_chain.ex`.

## PR2: The Chain (base: PR1 branch)

### Phase 1 — Skeleton + registration
- [x] 1.1 Create `lib/alethea/ai/chains/functional_analysis_draft_chain.ex`: `@behaviour ChainBehaviour`, alias `ClinicalSafetyPatterns`/`LLMConfig`/`StructuredOutput`; `eorc_fields/0` (11 literals per exploration.md:17-27); `functional_analysis_schema/0`.
- [x] 1.2 Edit `lib/alethea/ai/llm_config.ex`: add `:functional_analysis_draft` to `chain_name` type; add `chain_module(:functional_analysis_draft)` clause.
- [x] 1.3 AD5 wiring: `test/test_helper.exs` add `Mox.defmock(Alethea.AI.FunctionalAnalysisDraftChainMock, for: ChainBehaviour)`; `config/test.exs` add `config :alethea, :functional_analysis_draft_chain, ...Mock`.

### Phase 2 — build_prompt/1 + suggested_system_prompt/0
- [x] 2.1 RED chain test: numbers each evidence line, embeds text, refutes `chunk_id`/`resource_id`/`target_behavior_id` (spec: prompt scenario).
- [x] 2.2 GREEN `build_prompt/1`: header + numbered evidence, no identifiers.
- [x] 2.3 RED: `suggested_system_prompt/0` asserts 4 verbatim `NUNCA` rules, names all 11 fields, refutes `previous_notes` (spec: system-prompt scenario).
- [x] 2.4 GREEN `suggested_system_prompt/0` via `StructuredOutput.with_schema/2`; moduledoc note: callers prepend target-behavior description to `sanitized_evidence` if anchoring desired (AD4).

### Phase 3 — parse/1 (D3 gate + D4 partial)
- [x] 3.1 RED: clean-11, fenced-equivalence, leading/trailing fence, `properties`-echo, schema-shape-echo→unparseable, zero-field→unparseable, non-JSON→unparseable.
- [x] 3.2 RED: partial 8-of-11 exactly those 8 keys; model-emitted `""` → key absent (D4 scenarios).
- [x] 3.3 RED: diagnostic match blanks only that field, prescriptive match blanks only that field, absent-vs-blanked distinguishable, all-11-blanked still `{:ok, 11 keys}` (D3 scenarios).
- [x] 3.4 GREEN `parse/1`: `parse_json_response` → `unwrap_schema_echo` → `extract_fields/1` → `flagged?/1` blank → size check, per design's 5-step algorithm.
- [x] 3.5 RED+GREEN `do_run/2`: telemetry chain `:functional_analysis_draft`, mirrors `ClinicalHypothesisChain:122-155`.

### Phase 4 — Config, structural safety, AD3 parity
- [x] 4.1 RED+GREEN: `supported_providers() == [:local]`; refute `:cloud`; static refute source `:cloud`; `LLMConfig.get_and_build(:functional_analysis_draft)` → `provider == :local` (spec: LLMConfig requirement).
- [x] 4.2 RED+GREEN: static refute `create_clinical_note`/`accept_ai_proposal`/`edit_ai_proposal`/`discard_ai_proposal`/`upsert_functional_analysis_draft`/`upsert_functional_analysis_content`/`"Alethea.ClinicalRecord"`/`"Repo."` (spec: never-calls-mutation scenario).
- [x] 4.3 RED+GREEN: AD3 parity test — `eorc_fields()` == `%FunctionalAnalysisContent{}` struct keys minus `previous_notes`.
- [x] 4.4 RED+GREEN: mock wiring test mirroring `clinical_hypothesis_chain_test.exs:162-181`.
- [x] 4.5 `mix precommit` deferred to orchestrator per protocol (focused suites + `mix compile --warnings-as-errors --force` + `mix format --check-formatted` run instead, all clean); table-drove the fence-variant and D3-blanking fixtures via `for` comprehensions per this task's instruction, but PR2 still lands at ~543 authored lines (234 chain + 303 test + 6 config), well over the 400-line budget — **flagged to orchestrator: `size:exception` needed** (see apply-progress for full rationale; design.md pre-authorized this fallback: "splitting `parse/1` away from the module that calls it would break TDD atomicity").
