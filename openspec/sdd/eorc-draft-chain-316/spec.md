# Spec: E-O-R-C Functional Decomposition Draft Chain (#316)

## Domain: `functional-analysis-eorc-drafting` (New Capability)

## Purpose

How sanitized evidence becomes an eleven-field E-O-R-C draft via `FunctionalAnalysisDraftChain`; what it must never do; how diagnostic/prescriptive text is blanked (D3); how partial/malformed output is handled (D4). Includes additive `StructuredOutput` (D1) and `LLMConfig` requirements.

## Requirements

### Requirement: Prompt maps evidence to E-O-R-C fields, forbids diagnosis

`build_prompt/1` MUST be pure and produce a prompt instructing the model to populate the eleven `FunctionalAnalysisContent` fields (all but `previous_notes`) from given evidence. `suggested_system_prompt/0` MUST explicitly forbid diagnosis, forbid prescription/treatment recommendation, and forbid a factual/conclusive tone.

#### Scenario: Prompt references evidence and all eleven fields
- GIVEN sanitized evidence excerpts
- WHEN `build_prompt/1` runs
- THEN the prompt/schema names all eleven fields, excludes `previous_notes`

#### Scenario: System prompt forbids diagnosis and prescription
- GIVEN `suggested_system_prompt/0`
- WHEN inspected
- THEN it forbids diagnosis, forbids prescribing/recommending treatment, forbids factual/conclusive tone

### Requirement: `parse/1` extracts fields, tolerating fences and schema echo

`parse/1` MUST be pure and extract fields from: clean JSON, complete leading+trailing fenced JSON, and `{"properties": {...}}`-echoed JSON.

#### Scenario: Clean and fenced responses parse identically
- GIVEN a clean JSON response and its fully-fenced equivalent
- WHEN `parse/1` runs on each
- THEN both return `{:ok, map}` with identical field values

#### Scenario: Schema-echoed response parses
- GIVEN `{"properties": {"antecedents_distal": "...", ...}}`
- WHEN `parse/1` runs
- THEN fields are extracted from inside `properties`

### Requirement: `parse/1` is partial-tolerant (D4)

`parse/1` MUST return `{:ok, partial_map}` when ≥1 of 11 fields parses; unparsed fields are ABSENT (no key), never present with a default. `{:error, :unparseable}` only when zero fields parse.

#### Scenario: 8-of-11 valid fields returns exactly those 8 keys
- GIVEN 8 valid, 3 malformed/missing fields
- WHEN `parse/1` runs
- THEN `{:ok, map}` with exactly the 8 parsed keys; the 3 others are absent

#### Scenario: Zero valid fields is unparseable
- GIVEN non-JSON or JSON with no recognizable field
- WHEN `parse/1` runs
- THEN `{:error, :unparseable}`

#### Scenario: Absent key vs. blanked key are distinguishable
- GIVEN one field never parses and a second parses but is blanked (D3)
- WHEN `parse/1` runs
- THEN the never-parsed key is absent; the blanked key is present with value `""`

### Requirement: Per-field diagnostic/prescriptive blanking, siblings untouched (D3)

For each successfully-parsed field, `parse/1` MUST scan its text against the existing diagnostic/prescriptive lexical pattern functions and set only that field to `""` on a match. No sibling field is altered; no whole-response rejection occurs.

#### Scenario: Diagnostic-pattern match blanks only that field
- GIVEN `response_cognitive` matches a diagnostic pattern, 10 others are ordinary text
- WHEN `parse/1` runs
- THEN `response_cognitive` is `""`; every other present key is unchanged

#### Scenario: Prescriptive-pattern match blanks only that field
- GIVEN `consequences_long_term` matches a prescriptive pattern, 10 others are ordinary
- WHEN `parse/1` runs
- THEN `consequences_long_term` is `""`; every other present key is unchanged

### Requirement: Chain never calls a clinical-record mutation function

No code path in the chain (prompt builder, parser, run path) MUST create a clinical note, upsert functional analysis content, accept/edit/discard an AI proposal, or write to the clinical-record store. `run/1` MUST return only `{:ok, draft_map}` or `{:error, term}`.

#### Scenario: Chain behavior never reaches a write path
- GIVEN the chain's full implementation
- WHEN its behavior is inspected end-to-end
- THEN no clinical-record creation/upsert/accept/edit/discard occurs; `run/1` returns only a draft map or error tuple

### Requirement: Registered local-only in `LLMConfig`

`LLMConfig.chain_name` MUST gain `:functional_analysis_draft` resolving via `chain_module/1` to `FunctionalAnalysisDraftChain`. `supported_providers/0` MUST equal exactly `[:local]`.

#### Scenario: LLMConfig resolves to the local provider
- GIVEN `LLMConfig.get_and_build(:functional_analysis_draft)`
- WHEN built
- THEN `{:ok, config, llm}` with `config.provider == :local`

#### Scenario: Cloud provider is rejected
- GIVEN `supported_providers/0`
- WHEN inspected
- THEN it equals `[:local]`; `:cloud` is absent

## Domain: `Alethea.AI.StructuredOutput` (Modified — Additive Only)

### Requirement: `unwrap_schema_echo/1` generically unwraps a `properties` wrapper

New, opt-in function: given `%{"properties" => inner}`, returns `inner`; given a map without that key, returns it unchanged. Never invoked implicitly inside `parse_json_response/1`.

#### Scenario: Unwraps when wrapped, passes through when not
- GIVEN `%{"properties" => %{"f" => "v"}}` and `%{"f" => "v"}`
- WHEN `unwrap_schema_echo/1` runs on each
- THEN both return `%{"f" => "v"}`

### Requirement: `parse_json_response/1` strips trailing fences too

MUST strip both leading and trailing markdown fences before `Jason.decode`. Return contract (`{:ok, map()} | {:error, :invalid_json | :not_a_map}`) is otherwise unchanged.

#### Scenario: Fully-fenced JSON now decodes
- GIVEN a leading+trailing fenced JSON block
- WHEN `parse_json_response/1` runs
- THEN `{:ok, map}` (previously `{:error, :invalid_json}`)

#### Scenario: Unfenced behavior is unchanged
- GIVEN plain JSON, valid non-object JSON, and invalid JSON inputs
- WHEN `parse_json_response/1` runs
- THEN results match current behavior exactly (`{:ok, map}`, `{:error, :not_a_map}`, `{:error, :invalid_json}` respectively)

### Requirement: Existing callers stay behaviorally unchanged except newly-succeeding fences

The four current callers — `ClinicalHypothesisChain`, `ClinicalConsultationChain`, `WeeklySummaryChain`, `PatternProposalChain` — MUST keep their existing test suites green, unmodified. The only new observable behavior: a complete leading+trailing fenced input that previously errored now parses.

#### Scenario: All four callers' existing suites remain green
- GIVEN the D1 changes applied
- WHEN each caller's existing test suite runs
- THEN every previously-passing test still passes, unmodified

#### Scenario: A previously-failing fenced input now succeeds
- GIVEN raw model text in a complete leading+trailing fence, passed to any affected caller's parser
- WHEN parsed
- THEN extraction now succeeds where it previously errored solely due to the trailing fence

## Out of Scope (Boundary Requirements)

### Requirement: No LiveView, persistence, `PatternProposalChain`, or new policy module

This change MUST NOT touch any `lib/alethea_web/` file, `FunctionalAnalysisContent`, `Alethea.ClinicalRecord` write paths, `pattern_proposal_chain.ex` (D2), or introduce a new policy module (D3 uses plain function reuse only).

#### Scenario: Diff excludes all out-of-scope paths
- GIVEN the full diff for this change
- WHEN changed/added files are listed
- THEN no `lib/alethea_web/` file, no `functional_analysis_content.ex`/`clinical_record.ex` write path, no `pattern_proposal_chain.ex` change, and no new policy module appear
