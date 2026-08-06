```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:0fdf8028bdef9ffd81b76a8f34e6d4657961329a34fea7a5fafbdb1a6c859d46
verdict: fail
blockers: 1
critical_findings: 1
requirements: 4/5
scenarios: 5/6
test_command: mix precommit
test_exit_code: 0
test_output_hash: sha256:d2e9c3b4a6b42add3c32983920cc01849bd917dc903b2c317bebd0b48660385c
build_command: mix compile --warning-as-errors
build_exit_code: 0
build_output_hash: sha256:7acaf71bf4ac3d81c085e9675eda0157f2dd7919e05fed21d885e16bcddb2651
```

# Verification Report — retire-whatsapp-patient-identity (#107)

**Change**: retire-whatsapp-patient-identity · **Mode**: Strict TDD · hybrid artifact store
**Verdict: FAIL** — one required spec scenario has no covering test (CRITICAL UNTESTED). Everything else passes; the fix is a single small test.
**Suite**: `mix precommit` → 577 passed (6 doctests, 571 tests), 5 skipped, exit 0.

## Completeness (tasks)
| Phase | State | Verified against code |
|---|---|---|
| 1 save_message signature (ATOMIC) | [x] | clinical.ex now 7-arity; @spec trimmed; both callers fixed |
| 2 Patient schema removal (ATOMIC) | [x] | patient.ex has no whatsapp fields/cast/constraint |
| 3 Migration + rollback proof | [x] | up→down→up all GREEN (run live) |
| 4 accounts_test RED | [x] | rewritten test file present |
| 5 accounts.ex GREEN | [x] | create_patient KEK/DEK intact; dead readers deleted |
| 6 PatientLive.Index form | [x] | index_test present; no whatsapp input rendered |
| 7 stale-param cleanup | [x] | no stale whatsapp keys remain in test/ |
| 8 mix precommit GREEN | [x] | re-run live: 577 passed |
8/8 phases complete. No unchecked tasks. (Task completeness is NOT the blocker; scenario coverage is.)

## Build / Test evidence
- `mix precommit` (compile --warning-as-errors + format --check-formatted + test): exit 0, 577 passed / 5 skipped. Warnings-as-errors PASSES (unused `require Logger` was dropped). Format check passes.
- Migration proof (live): `mix ecto.rollback` ran `RetireWhatsappPatientIdentity.down/0` → recreated whatsapp_consent_logs + 3 indexes, re-added messages.whatsapp_message_id + unique index, re-added patients columns + unique index — all OK. `mix ecto.migrate` ran `up/0` → removed 3 columns + drop consent_logs — all OK. Both directions succeed.

## Spec compliance matrix (5 requirements / 6 scenarios)
| Scenario | Covering test | Status |
|---|---|---|
| Register patient with alias only | accounts_test:23 + index_test:22 | ✅ COMPLIANT |
| Registration provisions EncryptionKey + msg encrypt/decrypt round-trip | accounts_test:37 (key linkage) + :67 (round-trip asserts `{:ok, plaintext} == decrypt_message_content`) | ✅ COMPLIANT |
| Two patients same professional share alias | — none — | ❌ UNTESTED |
| Form omits WhatsApp field | index_test:10 (refutes input + privacy copy) | ✅ COMPLIANT |
| Submit form without WhatsApp value | index_test:22 (asserts success flash + patient persisted) | ✅ COMPLIANT |
| Telegram identity model untouched | No Foundation.Accounts.Patient change; full Telegram suite green | ✅ COMPLIANT (indirect) |
5/6 scenarios have a passing covering test. The uncovered one belongs to the MODIFIED "Patient Registration Identity" requirement.

## Highest-risk item — KEK/DEK preservation (create_patient/2) — PASS
Confirmed intact by source inspection (accounts.ex:221-273): DEK gen (`:crypto.strong_rand_bytes(32)`), KEK-wrap (`PatientVault.encrypt(dek, kek)`), the full `Ecto.Multi` (encryption_key insert → patient insert with `encryption_key_id` → finalize_key patient_id backfill), PubSub + audit side-effects. No phone derivation anywhere. The encrypt/decrypt round-trip test genuinely round-trips (encrypt on save via provisioned DEK, decrypt back to original plaintext, asserts equality AND ciphertext != plaintext). NOT a stub. This ripple guard is solid.

## Dead-reader removal — PASS
`rg` over `lib/`: `send_consent_terms`, `lookup_patient_by_phone`, `normalize_phone`, `encrypted_whatsapp_number`, `whatsapp_number_hash` (live code), `whatsapp_number`, `whatsapp_message_id` — ZERO live references. Remaining hits are docs/comments only (see SUGGESTIONS). save_message dedup `cond` and `{:error, :duplicate}` @spec removed. `lookup_patient_by_phone/1` and `normalize_phone/1` gone with no callers.

## Migration correctness — PASS
`up` removes 3 columns + `drop table(:whatsapp_consent_logs)`, NO explicit `drop index` (Postgres column cascade) — matches design ADR-2. `down` recreates columns + indexes + consent_logs. `down` consent_logs DDL is byte-for-byte equivalent to the original `20250601160000_add_whatsapp_consent_logs.exs` (id binary_id PK; whatsapp_number/status null:false; phone_hash; event_type; timestamps default now(); 3 indexes). Match confirmed. NOTE: on the dev DB this migration was PENDING before verification (first rollback hit an older migration); it is now applied. Test DB is separate and was migrated during the suite. Not a blocker.

## Atomic-group fixes — PASS
- `save_message` new 7-arity ⟺ callers: `save_telegram_message` (clinical.ex:131) passes `nil` dek + telegram_message_id as 7th positional (correct); `session_timeout_worker_test.exs:42` now 6-arg (patient,text,nil,dir,bt,session_id) — correct. Legacy `phone` binding at :51 is intentional (legacy-args perform_job test), not a create_patient param.
- Patient schema field removal ⟺ `daily_scheduler_worker_test.exs` struct literals: no whatsapp keys remain; suite compiles under --warnings-as-errors.

### TDD Compliance
| Check | Result | Details |
|---|---|---|
| TDD Evidence reported | ✅ | TDD Cycle Evidence table present in apply-progress (#210) |
| All tasks have tests | ✅ | Every phase maps to a real, present test file |
| RED confirmed (tests exist) | ✅ | accounts_test.exs + index_test.exs exist; pure-removal phases GREEN-only (correct for deletions) |
| GREEN confirmed (tests pass) | ✅ | 577 passed on live re-run |
| Triangulation adequate | ⚠️ | create_patient has 5 cases but the same-alias scenario has NO case |
| Safety Net for modified files | ✅ | Removal phases GREEN-only is design-correct |

### Test Layer Distribution
| Layer | Tests | Files |
|---|---|---|
| Unit/Context | 5 | accounts_test.exs (create_patient/2 describe) |
| Integration/LiveView | 2 | patient_live/index_test.exs |
| DB migration | 1 (manual live proof) | migration up/down/up |

### Changed File Coverage
Coverage analysis skipped — no coverage tool configured in precommit.

### Assertion Quality
Audited accounts_test.exs + index_test.exs. No tautologies, no orphan-empty checks, no ghost loops, no smoke-only tests, no implementation-detail coupling. The round-trip test exercises real production code (Clinical.save_message + decrypt) and asserts value equality. Form tests assert behavior (persisted patient, success flash), not markup internals. **Assertion quality: ✅ All assertions verify real behavior.**

### Quality Metrics
**Format**: ✅ `mix format --check-formatted` passed. **Compiler**: ✅ `--warning-as-errors` passed.

## Issues

### CRITICAL
1. **UNTESTED required scenario — "Two patients of the same professional may share an alias."** No test asserts two same-alias registrations both succeed without a uniqueness violation. Per the verify decision gate, an uncovered required scenario is CRITICAL `UNTESTED` and blocks a clean archive. Real failure risk is LOW (no uniqueness constraint ever existed on `Patient.alias`; the migration removes only the `whatsapp_number_hash` index), so the fix is a ~6-line test in the create_patient/2 describe (register two patients, same alias, same professional → both `{:ok, _}`). This is the ONLY blocker.

### WARNING
None.

### SUGGESTION (docs-only follow-ups, no compile/test impact)
2. `lib/alethea/DER.md:32` and `lib/alethea/accounts/CONTEXT.md:21-22` still describe the retired `whatsapp_number_hash` / `encrypted_whatsapp_number` fields (already flagged by apply).
3. `lib/alethea/telegram/log_redactor.ex:38` moduledoc still calls `whatsapp_number_hash` a "retained-but-dead column" — it is now fully dropped, so the comment is stale. NOT flagged by the apply report; fold into the same doc-cleanup follow-up.

## Verdict: FAIL (one CRITICAL, zero WARNING, three SUGGESTION)
The implementation is substantively sound: all 8 tasks complete and match code state, the KEK/DEK envelope (the whole point) is intact and rigorously guarded by a genuine encrypt/decrypt round-trip, the migration up/down is proven live, and the full suite is green under warnings-as-errors. The single blocker is a missing covering test for the "same-alias" spec scenario — a trivial, low-real-risk addition. Recommended route: sdd-apply to add that one test, then re-verify; after that the change is archive-ready. Three stale-doc references are non-blocking follow-ups.
