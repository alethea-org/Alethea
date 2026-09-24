# Design: E-O-R-C Functional Decomposition Draft Chain (#316)

**Inputs:** `proposal.md` (D1–D4 locked), `spec.md`, `exploration.md`
**Status:** design complete — D3 layering collision resolved (option **b**), one scope delta flagged, **budget forecast is over 400 lines → 2 chained PRs**

---

## Technical Approach

Four additive units plus one small, behavior-preserving extraction of already-shipped code:

```
[#319 caller]                         (not in this change)
     │  sanitized evidence strings
     ▼
FunctionalAnalysisDraftChain.build_prompt/1  (pure)
     │
     ▼  LLMChain (:local / phi4-mini, telemetry-wrapped do_run/2)
     │  raw model text
     ▼
StructuredOutput.parse_json_response/1   → fence-stripped JSON map
     ▼
StructuredOutput.unwrap_schema_echo/1    → {"properties" => …} unwrapped   (D1, opt-in)
     ▼
extract_fields/1   → keep 11 known keys, binary, non-blank        (D4 partial)
     ▼
flagged?/1 via ClinicalSafetyPatterns    → matching field ⇒ ""    (D3 blanking)
     ▼
{:ok, %{"antecedents_distal" => "...", ...}} | {:error, :unparseable}
```

---

## Architecture Decisions

### AD1 — D3 layering collision: extract a neutral pattern catalog (option **b**)

**Choice:** lift both regex lists **and** their shared normalization out of `HypothesisPolicy` into a new,
dependency-free **pattern catalog** — not a policy module — at
`lib/alethea/ai/clinical_safety_patterns.ex` (`Alethea.AI.ClinicalSafetyPatterns`).
`HypothesisPolicy` delegates to it; `FunctionalAnalysisDraftChain` consumes it.

**Rejected — option (a), narrow the new chain's static scan to write paths only.** It leaves a real
inverted dependency (`Alethea.AI` → `Alethea.ClinicalRecord.Rag.Consultation`) in place and permanently
gives the new chain a *weaker* structural guarantee than its sibling, for a saving of ~60 changed lines.
The weaker guard is the expensive part: the chain it protects writes into a persisted, encrypted,
RAG-indexed record once #319 lands, i.e. exactly the case that most needs the superset guard.

**Rejected — duplicating the two regex lists into the chain.** Two copies of a clinical-safety lexicon
drift silently; the next pattern added to one is missing from the other with no test to catch it.

**Rationale:**
1. Option (b) **preserves `ClinicalHypothesisChain`'s superset guard verbatim** on the new chain —
   `refute source =~ "Alethea.ClinicalRecord"` still passes, because the chain's only new alias is
   `Alethea.AI.ClinicalSafetyPatterns`. No safety guarantee is narrowed; nothing is dropped.
2. The direction it creates (`ClinicalRecord` → `Alethea.AI.<pure text module>`) is **already shipped
   precedent**: `lib/alethea/clinical_record/rag/consultation/live.ex:16` aliases `Alethea.AI.Sanitizer`,
   a pure, dependency-free text-hygiene module in the same namespace. The new module is its sibling in
   kind, and sits next to it in `lib/alethea/ai/`.
3. It does **not** violate the spec's "no new policy module" boundary: the catalog exports *data plus
   normalization only*. It has no `evaluate/2`, no reject reasons, no struct construction, no decision.
   `HypothesisPolicy` keeps its full gate precedence and its two distinct reject reasons; the chain owns
   its own (different) blank-on-any-match rule. Decision logic is not relocated, only the lexicon is.
4. Risk to shipped `HypothesisPolicy` tests is bounded and verifiable: `hypothesis_policy_test.exs`
   drives its table tests by **zipping the accessor lists 1:1 with fixed-order samples**
   (lines 161–223) and its static scan refutes only `Repo.` / `create_clinical_note` /
   `accept_ai_proposal` (lines 289–291) — it never refutes `Alethea.AI`. Keeping both accessors' names,
   arities, and **list order** unchanged keeps every one of those tests green unmodified.

**Catalog surface** (`lib/alethea/ai/clinical_safety_patterns.ex`):

```elixir
@spec diagnostic_patterns() :: [Regex.t()]      # the 9 regexes, order preserved verbatim
@spec prescriptive_patterns() :: [Regex.t()]    # the 9 regexes, order preserved verbatim
@spec normalize(String.t()) :: String.t()       # downcase + accent-fold (keeps ñ) + collapse whitespace
```

**`hypothesis_policy.ex` edits** (mechanical, behavior-preserving):

| Removed | Replaced by |
|---|---|
| `@diagnostic_patterns` / `@prescriptive_patterns` literals | — (moved verbatim to the catalog) |
| `def diagnostic_patterns`, `def prescriptive_patterns` bodies | `defdelegate diagnostic_patterns(), to: ClinicalSafetyPatterns` (+ prescriptive) |
| `@accent_map`, `fold_accents/1`, `normalize/1` bodies | `defp normalize(text), do: ClinicalSafetyPatterns.normalize(text)` |
| `Enum.any?(@diagnostic_patterns, …)` in `evaluate/2` | `Enum.any?(ClinicalSafetyPatterns.diagnostic_patterns(), …)` |

Runtime delegation (not a module attribute holding regexes) is deliberate — it keeps regex compilation
out of compile-time attributes and keeps the two accessors' existing compile-time use in the test file
working unchanged.

### AD2 — `parse/1` returns a **string-keyed** map

**Choice:** `{:ok, %{"antecedents_distal" => "…", …}}`, not atom keys.
**Rejected:** atom keys (`ClinicalHypothesisChain`'s shape).
**Rationale:** the downstream consumer is `FunctionalAnalysisContent.new/1`, which reads
`Map.get(params, Atom.to_string(field))` — string-keyed is the record's own contract, so #319 needs zero
conversion. It also avoids `String.to_existing_atom/1` on model-derived key names. `ClinicalHypothesisChain`'s
atom key is a single *fixed* result name; here the keys **are** the data contract.

### AD3 — the 11 field names are literal strings in the chain, guarded by a parity test

The chain **cannot** alias `Alethea.ClinicalRecord.FunctionalAnalysisContent` — that literal violates the
superset guard. So `@eorc_fields` is 11 string literals, exposed as `@doc false def eorc_fields/0`, and the
**test** (which is not scanned) asserts parity against `%FunctionalAnalysisContent{}`'s struct keys minus
`previous_notes`. Drift becomes a failing test instead of a silent mismatch.

### AD4 — input shape is a plain evidence list

`run(%{sanitized_evidence: texts})` / `build_prompt([String.t()])`, mirroring `PatternProposalChain` — the
sibling chain that consumes the *same* review-timeline evidence. **Rejected:** adding a `target_behavior`
parameter (`ClinicalHypothesisChain`'s `%{question:, excerpts:}` shape). It is caller knowledge owned by
#319, and #319 can prepend the behavior description as the first evidence line without a signature change.
*Flagged as a risk:* an E-O-R-C "R" is a behavior; an unanchored draft may be vaguer than a behavior-anchored one.

### AD5 — scope delta: ship the Mox registration here

The proposal lists Mox registration as out of scope ("no caller exists yet"). Design recommends **including
it** (2 lines + 2 assertions): it mirrors `ClinicalHypothesisChain` exactly (which ships its mock and asserts
the wiring in `describe "chain mock wiring"`), an unused mock is inert, and it keeps #319 from having to edit
shared test infrastructure. **Flagged to the orchestrator as a scope delta — vetoable in `sdd-tasks`.**

---

## Interfaces / Contracts

### `Alethea.AI.StructuredOutput` (modify) — D1

```elixir
@spec unwrap_schema_echo(map()) :: map()
def unwrap_schema_echo(%{"properties" => inner}) when is_map(inner), do: unwrap_schema_echo(inner)
def unwrap_schema_echo(other), do: other
```

Total, recursive (handles double-echo), terminating (maps are finite and acyclic), **opt-in** — never called
from `parse_json_response/1`. Unwrapping discards schema-metadata siblings (`"type"`, `"required"`), which is
the intent. *Rejected:* guarding the unwrap on "does the inner map contain expected keys" — that couples a
generic helper to a caller's key set; none of the 11 field names is `"properties"`, so the false-positive
surface is nil.

**Fence fix** inside `parse_json_response/1`:

```elixir
# before                                    # after
response                                    response
|> String.replace(~r/^```json\s*/i, "")     |> String.trim()
|> String.replace(~r/^```\s*/i, "")         |> String.replace(~r/^```(?:json)?\s*/i, "")
|> String.trim()                            |> String.replace(~r/\s*```$/, "")
                                            |> String.trim()
```

**Compatibility proof for the 4 callers** (`ClinicalHypothesisChain:107`, `ClinicalConsultationChain:100`,
`WeeklySummaryChain:90`, `PatternProposalChain:111`): a JSON document that decodes successfully always ends in
`}` or `]`, so the end-anchored `\s*```$` can never fire on input that succeeds today. The merged leading
alternation is equivalent to the two sequential leading replaces for every realistic input. The leading
`String.trim()` additionally rescues whitespace-prefixed fences. Every behavior change is therefore strictly
`{:error, :invalid_json}` → `{:ok, map}`. `{:error, :not_a_map}` is untouched.

### `Alethea.AI.Chains.FunctionalAnalysisDraftChain` (new)

`lib/alethea/ai/chains/functional_analysis_draft_chain.ex`

```elixir
@behaviour Alethea.AI.Chains.ChainBehaviour
alias Alethea.AI.{ClinicalSafetyPatterns, LLMConfig, StructuredOutput}

@impl true def run(%{sanitized_evidence: texts}) when is_list(texts)   # LLMConfig.get_and_build(:functional_analysis_draft) → do_run/2
@impl true def run!(params)
@impl true def suggested_system_prompt() :: String.t()                 # StructuredOutput.with_schema(base, functional_analysis_schema())
@impl true def suggested_max_tokens(), do: 1024                        # 11 prose fields ≫ ClinicalHypothesisChain's single 384-token field
@impl true def supported_providers(), do: [:local]                     # decrypted PHI in prompt — no :cloud literal anywhere in the file
@doc false @spec functional_analysis_schema() :: map()                 # object, 11 string properties, "required" = all 11
@doc false @spec eorc_fields() :: [String.t()]                         # AD3 parity accessor
@spec build_prompt([String.t()]) :: String.t()                         # pure
@spec parse(String.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, :unparseable}
defp do_run(llm, content)                                              # telemetry chain: :functional_analysis_draft
```

**System prompt** (Spanish, matching every sibling chain). Structure:
1. Role: *borrador* of an E-O-R-C functional analysis for the psychologist to review and edit — not a report, not a conclusion.
2. Strict rules, verbatim-assertable lines: `NUNCA diagnostiques` (no disorder names, no clinical pictures, no DSM/CIE criteria) · `NUNCA recomiendes tratamiento, medicación, derivación ni intervención` · `NUNCA uses tono de hecho consumado` · `NUNCA completes con conocimiento general: usa solo la evidencia entregada`.
3. Empty-field rule: if the evidence does not cover a field, return `""` for it.
4. Field glossary: one line per E-O-R-C field mapping evidence → field meaning (distal vs. immediate antecedents; sleep / pain / hunger / learning-history organism variables; physiological / cognitive / motor response; short- vs. long-term consequences).
5. `previous_notes` explicitly absent from both glossary and schema.

**`build_prompt/1`**: `"Evidencia clínica registrada en la línea de tiempo:\n"` + evidence numbered
`1.`…`n.` (numbering follows `ClinicalHypothesisChain`; the header follows `PatternProposalChain`). No
`chunk_id` / `resource_id` / `target_behavior_id` — no channel to fabricate a citation.

**`parse/1` algorithm** (order is load-bearing):

```
1. StructuredOutput.parse_json_response(raw)      → {:error, _} ⇒ {:error, :unparseable}
2. StructuredOutput.unwrap_schema_echo(decoded)
3. extract_fields/1 — for each of the 11 known keys, keep it only when the value
   is a binary whose String.trim/1 is non-empty   (non-binary or blank ⇒ key ABSENT)
4. per surviving field: flagged?(trimmed) ⇒ value becomes ""   (key PRESENT, D3)
5. map_size(extracted) > 0 ⇒ {:ok, extracted}, else {:error, :unparseable}   (D4)
```

`defp flagged?(text)` — `normalized = ClinicalSafetyPatterns.normalize(text)`, then
`Enum.any?(diagnostic_patterns() ++ prescriptive_patterns(), &Regex.match?(&1, normalized))`.
The chain does not distinguish the two reject reasons (unlike `HypothesisPolicy`); both blank identically.

**Contract consequences** (all spec'd, all tested):
- ABSENT key = the model never produced usable text. PRESENT `""` = it did, and the safety gate removed it.
- Step 5 counts **parsed** fields, so a response where all 11 fields are blanked still returns
  `{:ok, %{… 11 keys all ""}}` — the fields parsed; D3 gated them. Consistent with D4's "zero *parsed*" rule.
- A model that echoes the schema *shape* (`%{"antecedents_distal" => %{"type" => "string"}}`) yields
  0 binaries ⇒ `{:error, :unparseable}`.

### `Alethea.AI.LLMConfig` (modify)

```elixir
| :consultation_hypothesis
| :functional_analysis_draft                                                      # closed chain_name union, line ~33
defp chain_module(:functional_analysis_draft), do: Alethea.AI.Chains.FunctionalAnalysisDraftChain   # line ~241
```
No `config/*.exs` chain entry needed: `get/2` falls back to `provider: :local` + `phi4-mini`, exactly as
`:consultation_hypothesis` does today.

### Mox wiring (AD5 scope delta)

```elixir
# test/test_helper.exs
Mox.defmock(Alethea.AI.FunctionalAnalysisDraftChainMock, for: Alethea.AI.Chains.ChainBehaviour)
# config/test.exs
config :alethea, :functional_analysis_draft_chain, Alethea.AI.FunctionalAnalysisDraftChainMock
```

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/alethea/ai/clinical_safety_patterns.ex` | Create | AD1 neutral catalog: 2 regex lists + `normalize/1`. No deps. |
| `lib/alethea/clinical_record/rag/consultation/hypothesis_policy.ex` | Modify | AD1 delegation; zero behavior change; list order preserved |
| `lib/alethea/ai/chains/functional_analysis_draft_chain.ex` | Create | The chain (D3 gate + D4 partial contract) |
| `lib/alethea/ai/structured_output.ex` | Modify | D1: `unwrap_schema_echo/1` + fence fix |
| `lib/alethea/ai/llm_config.ex` | Modify | `:functional_analysis_draft` type member + `chain_module/1` clause |
| `test/test_helper.exs`, `config/test.exs` | Modify | AD5 Mox wiring (scope delta) |
| `test/alethea/ai/clinical_safety_patterns_test.exs` | Create | Catalog list identity + `normalize/1` accent/case folding |
| `test/alethea/ai/structured_output_test.exs` | Create | D1 regression (module has no tests today) |
| `test/alethea/ai/chains/functional_analysis_draft_chain_test.exs` | Create | Prompt / parse / blanking / partial / provider / structural |
| `lib/alethea/ai/chains/pattern_proposal_chain.ex` | **Untouched (D2)** | Follow-up cleanup ticket only |

---

## Testing Strategy (Strict TDD — RED before GREEN for every unit)

| File | Coverage |
|---|---|
| `structured_output_test.exs` | `unwrap_schema_echo/1`: wrapped → inner · unwrapped → identity · double-wrapped → innermost · `"properties"` mapped to a non-map → identity · empty map → identity. `parse_json_response/1`: no fence (unchanged) · leading-only fence · **trailing-only fence** · both fences · `json`-tagged and bare fences · whitespace-padded fence · malformed JSON → `{:error, :invalid_json}` · valid non-object JSON → `{:error, :not_a_map}` (contract-unchanged assertions) |
| `clinical_safety_patterns_test.exs` | `diagnostic_patterns/0` / `prescriptive_patterns/0` return 9 regexes each in the documented order; `HypothesisPolicy.diagnostic_patterns() == ClinicalSafetyPatterns.diagnostic_patterns()` (delegation parity, both lists); `normalize/1` downcases, folds `á é í ó ú ü`, keeps `ñ`, collapses whitespace |
| `hypothesis_policy_test.exs` | **Unmodified.** Must stay green — it is the regression proof for AD1 |
| `functional_analysis_draft_chain_test.exs` | `build_prompt/1`: numbers each evidence line, embeds evidence text, refutes `chunk_id`/`resource_id`/`target_behavior_id`. `suggested_system_prompt/0`: asserts the four verbatim `NUNCA` rules, names all 11 fields, refutes `previous_notes`. `parse/1`: all-11 clean table · fully-fenced equivalence (identical result to clean) · leading-only and trailing-only fence · `{"properties": …}` echo · schema-shape echo (non-binary values) → `:unparseable` · partial 8-of-11 (exactly those 8 keys, 3 absent) · model-emitted `""` → key absent · zero-field → `:unparseable` · non-JSON → `:unparseable`. **Blanking:** diagnostic text in `response_cognitive` → `""` while 10 siblings unchanged · prescriptive text in `consequences_long_term` → `""` while siblings unchanged · absent-vs-blanked distinguishability · all-11-blanked still `{:ok, 11 keys}`. **Config:** `supported_providers() == [:local]`, `refute :cloud in …`, static `refute source =~ ":cloud"`, `LLMConfig.get_and_build(:functional_analysis_draft)` → `provider == :local`. **Mock wiring** (AD5). **AD3 parity** test vs. `%FunctionalAnalysisContent{}` struct keys. **Structural safety (AD1 resolution — full guard, unnarrowed):** `refute source =~` each of `create_clinical_note`, `accept_ai_proposal`, `edit_ai_proposal`, `discard_ai_proposal`, `upsert_functional_analysis_draft`, `upsert_functional_analysis_content`, `"Alethea.ClinicalRecord"`, `"Repo."` |

No integration or E2E layer: #316 ships no caller by design. Live-endpoint validation happens manually at #319 — the same gap every existing chain has.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. The change is pure in-process text transformation plus one local HTTP LLM call through the existing `OllamaChat` adapter.

## Migration / Rollout

No migration. No feature flag. No caller in any shipped user path — the caller is #319, so a revert cannot break a live flow. Rollback = delete the chain + catalog + three test files, revert the `HypothesisPolicy` delegation to inline attributes, drop the two `LLMConfig` clauses, and revert the two `StructuredOutput` additions (restoring the prior, buggy fence behavior).

## Review Workload Forecast

**Decision needed before apply: Yes**
**Chained PRs recommended: Yes**
**400-line budget risk: High**

| Unit | Est. changed lines |
|---|---|
| `clinical_safety_patterns.ex` (new) | ~70 |
| `hypothesis_policy.ex` (−47 / +10) | ~57 |
| `structured_output.ex` (+20 / −4) | ~24 |
| `clinical_safety_patterns_test.exs` (new) | ~30 |
| `structured_output_test.exs` (new) | ~90 |
| **Slice 1 subtotal** | **~271** |
| `functional_analysis_draft_chain.ex` (new) | ~190 |
| `llm_config.ex` + Mox wiring | ~4 |
| `functional_analysis_draft_chain_test.exs` (new) | ~220 |
| **Slice 2 subtotal** | **~414** |
| **Total** | **~685** |

The proposal's ~280–380 estimate predates AD1's extraction and understates the 11-field chain and its test
table. **As a single PR this change is ~1.7× the budget.** Recommended Feature Branch Chain:

- **PR 1 — shared parsing + safety foundations** (~271). `StructuredOutput` D1 + `ClinicalSafetyPatterns`
  extraction + `HypothesisPolicy` delegation + both new test files. Autonomous: independently verifiable
  (`hypothesis_policy_test.exs` green unmodified is the whole proof), independently revertible, ships real
  value (fixes the live trailing-fence bug for three shipped chains).
- **PR 2 — the chain** (~414), targeting PR 1's branch. The chain, `LLMConfig`, Mox wiring, chain test.

PR 2 sits ~3% over budget. Trim levers, in order: table-drive the 11-field fixtures via a single module
attribute and `for` comprehensions in the test (~−25), and keep the field glossary to one line per field
(~−10). If it still lands over 400, `size:exception` is the appropriate resolution — splitting `parse/1`
away from the module that calls it would break TDD atomicity and produce a non-compiling intermediate slice.

## Open Questions

- [ ] **AD5 scope delta** — design recommends shipping the Mox registration that the proposal deferred to #319. Orchestrator/user may veto in `sdd-tasks`; cost of vetoing is 4 lines moved to #319.
- [ ] **AD4** — no `target_behavior` input. Confirm #319 can anchor the draft by prepending the behavior description to the evidence list; otherwise the signature needs one field and this design section changes.
- [ ] **D2 obligation** — the `PatternProposalChain` cleanup follow-up ticket must actually be filed; once `unwrap_schema_echo/1` exists, that chain's local fence-strip and its two-clause `properties` match are dead weight.
