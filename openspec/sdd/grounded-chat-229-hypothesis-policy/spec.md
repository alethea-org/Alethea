# Clinical Consultation Hypothesis Specification

## Purpose

Defines the testable policy deciding whether a grounded consultation answer may additionally carry a revisable "Hipótesis para revisar" (ADR-010 §2): interpretive-only triggering, mandatory server-derived citations, structural rejection of diagnostic/prescriptive language, and a mandatory disclaimer. Scope: standalone `Hypothesis`, `HypothesisPolicy`, `ClinicalHypothesisChain`. Wiring into the real consultation flow is explicitly excluded (#235).

## Requirements

### Requirement: Interpretive Intent Classification
`HypothesisPolicy.interpretive_intent?/1` MUST be a pure, deterministic function over Spanish interrogative/relational markers and MUST NOT call any LLM or external service.

#### Scenario: Factual query is not interpretive
- GIVEN a clearly factual question (e.g. asks for a specific date)
- WHEN `interpretive_intent?/1` evaluates it
- THEN it returns `false`

#### Scenario: Interpretive query is classified as interpretive
- GIVEN a question uses a Spanish pattern/relational marker (e.g. "¿qué relación hay entre...", "¿qué patrón...")
- WHEN `interpretive_intent?/1` evaluates it
- THEN it returns `true`

#### Scenario: Ambiguous phrasing is deterministic
- GIVEN the same ambiguous Spanish phrasing is evaluated twice
- WHEN `interpretive_intent?/1` runs both times
- THEN both calls return the identical boolean

### Requirement: Hypothesis Value Object Contract
`Consultation.Hypothesis` MUST be a struct whose `@enforce_keys` cover at least `statement`, `sources`, and `disclaimer`.

#### Scenario: Struct rejects missing disclaimer
- GIVEN code builds `%Hypothesis{}` omitting `disclaimer`
- WHEN evaluated
- THEN it raises `ArgumentError`

### Requirement: Sole Constructor Gate
`HypothesisPolicy.evaluate/2` MUST be the only function in the codebase that constructs a `%Hypothesis{}`.

#### Scenario: No other construction site exists
- GIVEN a static source scan for `%Hypothesis{` outside `hypothesis.ex`/`hypothesis_policy.ex`
- WHEN the scan runs
- THEN no other construction site is found

### Requirement: Mandatory Server-Derived Citations
Every `Hypothesis` from `evaluate/2` MUST carry one or more `Consultation.Source.t()` entries; zero sources MUST yield no hypothesis.

#### Scenario: Empty sources reject the hypothesis
- GIVEN an interpretive candidate with zero `Source` entries
- WHEN `evaluate/2` runs
- THEN it returns no `%Hypothesis{}` (e.g. `{:reject, :no_evidence}`)

#### Scenario: Non-empty sources attach unmodified
- GIVEN an interpretive candidate with ≥1 retrieval-derived `Source` and no forbidden language
- WHEN `evaluate/2` runs
- THEN the returned `sources` equals exactly those `Source.t()` structs

### Requirement: Structural Rejection of Diagnostic/Prescriptive Content
`evaluate/2` MUST scan the candidate statement against an exported, test-visible forbidden-pattern list and reject the ENTIRE hypothesis on any match — never partial redaction, never retry.

#### Scenario: Diagnostic language rejects the whole hypothesis
- GIVEN a statement containing a diagnostic marker (e.g. "trastorno de")
- WHEN `evaluate/2` runs with valid sources
- THEN it returns no hypothesis, and no redacted variant is returned

#### Scenario: Prescriptive language rejects the whole hypothesis
- GIVEN a statement containing a prescriptive marker (e.g. "deberías iniciar")
- WHEN `evaluate/2` runs with valid sources
- THEN it returns no hypothesis

#### Scenario: Clean statement passes the gate
- GIVEN a statement with no forbidden marker and valid sources
- WHEN `evaluate/2` runs
- THEN it returns `{:ok, %Hypothesis{}}`

#### Scenario: Static scan proves no diagnosis/treatment call path
- GIVEN `ClinicalHypothesisChain`'s source
- WHEN a static source-scan test inspects its calls
- THEN it contains no call into any diagnosis-writing or treatment-recommending code

### Requirement: Mandatory Clinical Disclaimer
Every `%Hypothesis{}` MUST carry the exact constant `"Hipótesis para revisar: no es un diagnóstico ni una recomendación terapéutica."`, sourced from a module constant, never LLM-authored.

#### Scenario: Disclaimer is injected verbatim
- GIVEN `evaluate/2` accepts a candidate
- WHEN the resulting `%Hypothesis{}` is inspected
- THEN `disclaimer` equals the exact constant, regardless of the LLM's raw output

#### Scenario: LLM-echoed wording is ignored
- GIVEN the LLM's `statement` text happens to include disclaimer-like wording
- WHEN `evaluate/2` builds the struct
- THEN `disclaimer` is still the server constant, never derived from `statement`

### Requirement: Clinical Hypothesis Generation Chain
`Alethea.AI.Chains.ClinicalHypothesisChain` MUST mirror `ClinicalConsultationChain`'s shape: `supported_providers/0` returns `[:local]`; `build_prompt/1`/`parse/1` are pure; `parse/1` fails loud on empty/malformed output; the prompt carries no chunk/resource identifiers.

#### Scenario: Chain is local-only
- GIVEN `ClinicalHypothesisChain.supported_providers/0`
- WHEN called
- THEN it returns `[:local]`

#### Scenario: Malformed output fails loud
- GIVEN an empty or invalid raw model response
- WHEN `parse/1` runs
- THEN it returns an error tuple, never a blank/placeholder hypothesis

#### Scenario: Prompt carries no citation identifiers
- GIVEN `build_prompt/1` with excerpts and a question
- WHEN the built prompt is inspected
- THEN it contains no chunk id, resource id, or other reference identifier

### Requirement: Chain Registration in LLMConfig
`LLMConfig.chain_name` MUST gain a `:consultation_hypothesis` clause and `chain_module/1` MUST map it to `ClinicalHypothesisChain`, without altering existing clauses.

#### Scenario: New chain resolves correctly
- GIVEN `LLMConfig.get_and_build(:consultation_hypothesis)`
- WHEN invoked
- THEN it resolves to `ClinicalHypothesisChain` and succeeds like other `:local`-only chains

#### Scenario: Existing chain clauses are untouched
- GIVEN all prior `chain_name` values (`:guided_conversation`, `:session_summary`, `:weekly_summary`, `:weekly_report`, `:pattern_proposal`, `:consultation_synthesis`)
- WHEN the change is applied
- THEN every prior clause still compiles and resolves identically

### Requirement: No Wiring Into the Real Consultation Flow (boundary)
This slice MUST NOT add a 5th `Answer.outcome` value, MUST NOT modify `ClinicalConsultationChain`'s prompt/behavior, and MUST NOT call `Consultation.Live.answer/4` or touch `ConsultationLive`.

#### Scenario: Answer.outcome vocabulary is unchanged
- GIVEN `Answer.outcome/0` after this change
- WHEN compared to before
- THEN it remains exactly `:synthesis | :no_evidence | :stale | :provider_failure`

#### Scenario: ClinicalConsultationChain is byte-unchanged
- GIVEN `clinical_consultation_chain.ex` and its prompt regression test
- WHEN diffed against the pre-change version
- THEN there is no difference

#### Scenario: No call site touches the real consultation flow
- GIVEN a source scan of `Consultation.Live.answer/4` and `ConsultationLive`
- WHEN searching for references to `Hypothesis`, `HypothesisPolicy`, or `ClinicalHypothesisChain`
- THEN none exist
