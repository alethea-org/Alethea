# Tasks: Revisable Hypothesis Policy (#229)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | #229a ~315, #229b ~284 (total ~599) |
| 400-line budget risk | #229a Medium, #229b Low |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (#229a: struct+policy) → PR 2 (#229b: chain+LLMConfig) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | `Hypothesis` struct + `HypothesisPolicy` (interpretive gate, evidence gate, forbidden-pattern gate, disclaimer) | PR 1, base=`feat/grounded-clinical-chat-hypotheses` | `mix test test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` | N/A — pure functions, no external process; `mix test` is the full harness | Delete `hypothesis.ex`, `hypothesis_policy.ex`, their test, revert `answer.ex` field |
| 2 | `ClinicalHypothesisChain` + `LLMConfig` registration + Mox wiring + static source-scan test | PR 2, base=PR 1 branch | `mix test test/alethea/ai/chains/clinical_hypothesis_chain_test.exs` | `mix test` (Mox-mocked chain, no live Ollama call needed) | Delete `clinical_hypothesis_chain.ex`, its test, revert 2-line `llm_config.ex` diff + test-wiring lines |

If PR 1 overruns 400 lines: split marker-table tests into a third stacked `hypothesis_intent_test.exs` PR (design's contingency).

## Phase 1: #229a — `Hypothesis` value object (Requirement: Hypothesis Value Object Contract)

- [x] 1.1 RED: `test/alethea/clinical_record/rag/consultation/hypothesis_policy_test.exs` — `assert_raise ArgumentError, fn -> struct!(Hypothesis, %{}) end` (spec scenario "Struct rejects missing disclaimer").
- [x] 1.2 GREEN: create `lib/alethea/clinical_record/rag/consultation/hypothesis.ex` — `@enforce_keys [:statement, :sources, :disclaimer]`, `@disclaimer` module constant (exact D2 literal), `disclaimer/0` accessor, `@type t`.
- [x] 1.3 RED: test `Hypothesis.disclaimer() == "Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."` (golden, pins verbatim literal).

## Phase 2: #229a — `HypothesisPolicy.interpretive_intent?/1` (Requirement: Interpretive Intent Classification)

- [x] 2.1 RED: table-driven test in `hypothesis_policy_test.exs` — `for phrase <- @interpretive_phrases, do: test "...", do: assert HypothesisPolicy.interpretive_intent?(phrase)` covering causal/relational/pattern/interpretive marker groups (~16 phrases per design worked-examples table). Satisfies "Interpretive query is classified as interpretive".
- [x] 2.2 RED: table-driven test — `for phrase <- @factual_phrases, do: ... refute interpretive_intent?(phrase)` (~12 factual phrases incl. veto-wins case `"¿Por qué faltó? ¿Qué día fue?"`). Satisfies "Factual query is not interpretive".
- [x] 2.3 RED: determinism test — call `interpretive_intent?/1` twice on the same ambiguous phrase, assert identical result. Satisfies "Ambiguous phrasing is deterministic".
- [x] 2.4 RED: blank-guard test — `interpretive_intent?("")` and `interpretive_intent?("   ")` both `false`.
- [x] 2.5 RED: accent-fold parity test — `interpretive_intent?("por que")` == `interpretive_intent?("por qué")`.
- [x] 2.6 GREEN: create `lib/alethea/clinical_record/rag/consultation/hypothesis_policy.ex` — private `normalize/1` (downcase, accent-fold `á é í ó ú ü`→`a e i o u`, keep `ñ`, collapse whitespace), `@interpretive_markers`/`@factual_veto_markers` module attrs (AD3 markers table), `interpretive_intent?/1` with AD2 veto-wins-over-interpretive precedence.
- [x] 2.7 STATIC: add `hypothesis_policy.ex` purity check — `File.read!/1` + `refute source =~ "Repo."` / `refute source =~ "create_clinical_note"` / `refute source =~ "accept_ai_proposal"` (Requirement: Interpretive Intent Classification — "MUST NOT call any LLM or external service").

## Phase 3: #229a — `HypothesisPolicy.evaluate/2` gates (Requirements: Sole Constructor Gate, Mandatory Server-Derived Citations, Structural Rejection, Mandatory Clinical Disclaimer)

- [x] 3.1 RED: `evaluate(text, [])` → `{:reject, :no_evidence}` (scenario "Empty sources reject the hypothesis").
- [x] 3.2 RED: `evaluate("", [fixture_result])` and `evaluate("   ", [fixture_result])` → `{:reject, :empty_statement}` (design's 4th reason, precedence rule 2).
- [x] 3.3 RED: **ordering-critical** — clean candidate statement (no forbidden marker) + 1 `Fake`-shaped result → `{:ok, %Hypothesis{}}` whose `disclaimer` equals `Hypothesis.disclaimer()`; assert the gate does NOT reject even though the disclaimer text itself contains "diagnóstico"/"recomendación terapéutica" — proves AD5 (scan `candidate_text` only, never the assembled struct/disclaimer). Add explicit comment in the test naming this as the AD5 regression guard.
- [x] 3.4 RED: N results → N `%Source{}` in returned `sources`, order preserved, values equal `Source.from_results(results)` exactly (scenario "Non-empty sources attach unmodified").
- [x] 3.5 RED: table-driven diagnostic-language test — `for pattern <- HypothesisPolicy.diagnostic_patterns(), do: ...` plus explicit case `"presenta un trastorno de ansiedad"` → `{:reject, :diagnostic_language}`.
- [x] 3.6 RED: table-driven prescriptive-language test — `for pattern <- HypothesisPolicy.prescriptive_patterns(), do: ...` plus explicit cases `"deberías iniciar tratamiento"` and `"recomiendo derivar a psiquiatría"` → `{:reject, :prescriptive_language}`. Include a case asserting the regex `~r/\brecom(iend|end)\w*\b/i` matches "recomiendo" specifically (catches the design-doc regex typo `recomend(amos|ación)` that misses this conjugation).
- [x] 3.7 RED: negative-control test — legitimate tentative prose using `"sugiere"`, `"podría"`, `"es posible que"` (no banned pattern) is accepted, `{:ok, _}` (scenario "Clean statement passes the gate" / no-false-rejection).
- [x] 3.8 RED: `disclaimer` is never derived from `statement` — LLM-echoed text containing disclaimer-like wording still yields the server constant (scenario "LLM-echoed wording is ignored"); assert returned `statement` does not contain the disclaimer substring.
- [x] 3.9 GREEN: implement `evaluate/2` in `hypothesis_policy.ex` — `@diagnostic_patterns`/`@prescriptive_patterns` module attrs with `diagnostic_patterns/0`/`prescriptive_patterns/0` `@doc false` accessors; fixed precedence: `no_evidence` → `empty_statement` → diagnostic scan (on raw/normalized `candidate_text`, BEFORE disclaimer attachment) → prescriptive scan → `{:ok, %Hypothesis{statement: trimmed, sources: Source.from_results(results), disclaimer: Hypothesis.disclaimer()}}`. Verify each Spanish stem regex covers both infinitive/noun and one conjugated form per design's regex-correction note.
- [x] 3.10 STATIC: sole-constructor scan — `refute File.read!/1` output of every `lib/**/*.ex` file except `hypothesis.ex`/`hypothesis_policy.ex` contains `"%Hypothesis{"` (Requirement: Sole Constructor Gate scenario "No other construction site exists"). Run as one test iterating `Path.wildcard("lib/**/*.ex")`.

## Phase 4: #229a — wire `Answer` additively (Requirement: No Wiring boundary, partial)

- [x] 4.1 Modify `lib/alethea/clinical_record/rag/consultation/answer.ex` — add `alias ... Hypothesis`, add `hypothesis: Hypothesis.t() | nil` to `@type t`, add `:hypothesis` to `defstruct` (default `nil`), update moduledoc line. Do NOT touch `outcome` type or `@enforce_keys`.
- [x] 4.2 RED then GREEN: existing `consultation_test.exs` pattern matches still compile/pass unmodified — run `mix test test/alethea/clinical_record/rag/consultation_test.exs` (scenario "Answer.outcome vocabulary is unchanged").
- [x] 4.3 Confirm `Consultation.Fake` untouched — no diff to `fake.ex` (hypothesis defaults to `nil` via struct default).

## Phase 5: #229b — `ClinicalHypothesisChain` (Requirement: Clinical Hypothesis Generation Chain)

- [ ] 5.1 RED: `test/alethea/ai/chains/clinical_hypothesis_chain_test.exs` — `ClinicalHypothesisChain.supported_providers() == [:local]` (scenario "Chain is local-only").
- [ ] 5.2 RED: `build_prompt/1` test — given `%{question:, excerpts:}`, assert numbered excerpts + question present, and `refute prompt =~ "chunk_id"` / `"resource_id"` / `"target_behavior_id"` (scenario "Prompt carries no citation identifiers").
- [ ] 5.3 RED: `parse/1` table-driven test — `for bad <- [malformed_json, missing_key_json, "", "   "], do: assert parse(bad) == {:error, :unparseable}` (scenario "Malformed output fails loud").
- [ ] 5.4 RED: `parse/1` happy path — valid `%{"hypothesis" => "..."}` JSON → `{:ok, %{hypothesis: trimmed}}`.
- [ ] 5.5 RED: prompt golden test — `suggested_system_prompt/0` contains verbatim `"NO es un diagnóstico ni una recomendación terapéutica"`, verbatim `"no indiques tratamiento, medicación ni derivación"`, and the server-owns-disclaimer bullet text.
- [ ] 5.6 GREEN: create `lib/alethea/ai/chains/clinical_hypothesis_chain.ex` — mirror `clinical_consultation_chain.ex` shape exactly: `@behaviour ChainBehaviour`, `run/1`, `run!/1`, `suggested_system_prompt/0` (exact design system prompt text), `suggested_max_tokens/0` → `384`, `supported_providers/0` → `[:local]`, `@doc false hypothesis_schema/0`, `build_prompt/1`, `parse/1`, private `do_run/2` with `:telemetry.execute` tagged `chain: :clinical_hypothesis`.
- [ ] 5.7 STATIC: source-scan test (D3 layer 3, precedent `test/alethea_jobs/ai_proposal_worker_test.exs:135-155`) — `describe "structural safety"` in `clinical_hypothesis_chain_test.exs`: `File.read!` the chain source, `refute source =~` each of `"create_clinical_note"`, `"accept_ai_proposal"`, `"edit_ai_proposal"`, `"discard_ai_proposal"`, `"upsert_functional_analysis_draft"` (confirmed at `lib/alethea/clinical_record.ex:102,366,386,412,438`), plus superset guards `refute source =~ "Alethea.ClinicalRecord"` and `refute source =~ "Repo."` (Requirement: Structural Rejection scenario "Static scan proves no diagnosis/treatment call path").

## Phase 6: #229b — `LLMConfig` registration + Mox wiring (Requirement: Chain Registration in LLMConfig)

- [ ] 6.1 RED: `LLMConfig.get_and_build(:consultation_hypothesis)` resolves `{:ok, _, %OllamaChat{}}` with `provider == :local` (scenario "New chain resolves correctly").
- [ ] 6.2 RED: regression test — all six prior `chain_name` values (`:guided_conversation`, `:session_summary`, `:weekly_summary`, `:weekly_report`, `:pattern_proposal`, `:consultation_synthesis`) still resolve identically via `get_and_build/1` (scenario "Existing chain clauses are untouched").
- [ ] 6.3 GREEN: modify `lib/alethea/ai/llm_config.ex` — add `| :consultation_hypothesis` to `@type chain_name`, add `defp chain_module(:consultation_hypothesis), do: Alethea.AI.Chains.ClinicalHypothesisChain` clause. No other line touched.
- [ ] 6.4 Modify `config/test.exs` — add `config :alethea, :clinical_hypothesis_chain, Alethea.AI.ClinicalHypothesisChainMock` (mirrors existing `:clinical_consultation_chain` line).
- [ ] 6.5 Modify `test/test_helper.exs` — add `Mox.defmock(Alethea.AI.ClinicalHypothesisChainMock, for: Alethea.AI.Chains.ChainBehaviour)`.
- [ ] 6.6 RED/GREEN: Mox integration test — `import Mox`, `setup :verify_on_exit!`, mock `run/1` returns text derived only from given excerpts; assert dispatch reaches the mock in `:test` env.

## Phase 7: #229b — boundary regression (Requirement: No Wiring Into the Real Consultation Flow)

- [ ] 7.1 Diff `lib/alethea/ai/chains/clinical_consultation_chain.ex` against pre-change version — assert byte-identical (scenario "ClinicalConsultationChain is byte-unchanged"); run its existing prompt regression test unmodified.
- [ ] 7.2 STATIC: source scan of `Consultation.Live`/`ConsultationLive` call sites — `refute` any reference to `Hypothesis`, `HypothesisPolicy`, or `ClinicalHypothesisChain` (scenario "No call site touches the real consultation flow").
- [ ] 7.3 Run full suite `mix test` — confirm zero regressions across #226a/#226b tests.

## Phase 8: Final verification

- [ ] 8.1 `mix precommit` (compile, format, test) on both slices before opening each PR.
- [ ] 8.2 Confirm PR 1 diff excludes any `clinical_hypothesis_chain.ex`/`llm_config.ex` content (clean slice boundary); confirm PR 2 diff, based on PR 1's branch, shows only PR 2's own files when compared against PR 1 (not against the tracker) — retarget/rebase if GitHub shows PR 1's changes inside PR 2.
