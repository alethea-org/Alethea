# SDD Proposal: Integration and Testing Improvements

## Change ID
`sdd-integration-001`

## Change Name
Integration and Testing: E2E Coverage, API Contracts, and Quality Assurance

## Intent
The Alethea application needs comprehensive integration testing, contract verification for external services (WhatsApp, AI providers), and quality assurance tooling. This proposal establishes test coverage standards, adds critical integration tests, and implements contract testing to catch regressions before production deployment.

## Scope

### In-Scope Improvements

#### 1. WhatsApp Webhook Contract Tests (Complexity: 2/5)
**Current State**: No dedicated tests for webhook payload structure.

**Proposed Changes**:
- Create WhatsApp webhook payload fixtures in `test/fixtures/whatsapp/`:
  - `text_message.json` - standard text message
  - `image_message.json` - image message (for future media support)
  - `status_update.json` - message status changes
  - `invalid_signature.json` - signature verification failure
- Write property-based tests for payload parsing
- Add integration tests for signature verification edge cases
- Test rate limiting behavior under load

**Files Affected**:
- `test/fixtures/whatsapp/` - new fixture directory
- `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs` - new tests
- `test/support/fixtures/whatsapp_fixtures.ex` - helper functions

#### 2. E2E Test Suite with Wallaby (Complexity: 3/5)
**Current State**: Only controller and unit tests exist; no browser automation tests.

**Proposed Changes**:
- Add Wallaby to test dependencies
- Create E2E tests for critical user flows:
  - **Login flow**: professional login, session persistence, logout
  - **Patient lookup**: search, filter, navigate to detail
  - **Dashboard load**: patient list renders, no console errors
  - **Crisis alert flow**: simulate alert, verify notification appears
  - **Message viewing**: decrypt and display conversation history
- Configure ChromeDriver/Headless Chrome in CI
- Add `mix test.e2e` alias for browser tests only

**Files Affected**:
- `test/alethea_web/e2e/` - new E2E test directory
- `test/alethea_web/e2e/login_test.exs` - login flow
- `test/alethea_web/e2e/dashboard_test.exs` - dashboard tests
- `test/alethea_web/e2e/crisis_alert_test.exs` - crisis notification flow
- `test/support/conn_case.ex` - update for Wallaby
- `test/test_helper.exs` - Wallaby setup
- `config/test.exs` - Wallaby configuration
- `mix.exs` - add Wallaby dependency

#### 3. AI Service Mock and Contract Tests (Complexity: 3/5)
**Current State**: Tests directly call `RoBERTaWorker` and `PhiWorker` without mocking.

**Proposed Changes**:
- Create `FakeLLM` behavior matching `PhiWorker` interface
- Implement `FakeLLM` for tests returning deterministic responses
- Add contract tests for AI service responses:
  - RoBERTa output matches expected emotion labels
  - PhiWorker response length within expected bounds (50-2000 chars)
  - Response includes required context elements
- Mock external HuggingFace API responses for unit tests

**Files Affected**:
- `test/support/fakes/fake_llm.ex` - mock LLM implementation
- `test/support/fakes/fake_roberta.ex` - mock RoBERTa implementation
- `test/alethea/ai/phi_worker_test.exs` - update to use FakeLLM
- `test/alethea/ai/roberta_worker_test.exs` - update to use FakeRoBERTa
- `test/alethea/ai/guided_conversation_chain_test.exs` - contract tests

#### 4. Oban Job Testing Utilities (Complexity: 2/5)
**Current State**: Jobs tested with `Oban.Testing` but helpers are inconsistent.

**Proposed Changes**:
- Create `Alethea.Jobs.Case` test helper module:
  - `perform_job/2` helper for inline job execution
  - `assert_enqueued/2` for checking job enqueue
  - `refute_enqueued/2` for negative cases
- Standardize job test patterns across all workers
- Add integration tests for job chains (e.g., ProcessMessageWorker → EmotionAnalysisWorker → PhiWorker)

**Files Affected**:
- `test/support/alethea_jobs_case.ex` - new test helper
- `test/alethea_jobs/emotion_analysis_worker_test.exs` - refactored
- `test/alethea_jobs/session_timeout_worker_test.exs` - refactored
- `test/alethea_jobs/weekly_report_worker_test.exs` - refactored
- `test/alethea_jobs/process_message_worker_test.exs` - refactored

#### 5. API Documentation with OpenAPI (Complexity: 3/5)
**Current State**: No API documentation for webhook endpoints.

**Proposed Changes**:
- Add `phoenix_swagger` or `open_api_spex` dependency
- Document WhatsApp webhook endpoint:
  - Request format (signature header, body schema)
  - Response codes (200 OK, 400 Bad Request, 429 Rate Limited)
  - Rate limit headers
- Document health check endpoints
- Generate Swagger UI at `/api/docs`
- Add request/response examples using fixtures

**Files Affected**:
- `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` - add spec
- `lib/alethea_web/controllers/health_controller.ex` - add spec
- `lib/alethea_web/router.ex` - mount Swagger UI
- `priv/static/swagger.json` - generated documentation
- `config/config.exs` - OpenAPI configuration
- `mix.exs` - add dependency

#### 6. Chaos Testing for Encryption (Complexity: 3/5)
**Current State**: No fault injection testing for encryption layer.

**Proposed Changes**:
- Add property-based tests for `PatientVault`:
  - Encrypt/decrypt roundtrip
  - Tampered ciphertext detection
  - Key rotation scenarios
- Add integration tests with simulated KEK loss:
  - Verify decryption fails gracefully
  - Verify audit log captures failure
- Test large message encryption (10KB, 100KB boundaries)

**Files Affected**:
- `test/alethea/encryption/patient_vault_test.exs` - new tests
- `test/alethea/encryption/professional_kek_test.exs` - new tests
- `test/support/fakes/fake_vault.ex` - chaos scenarios

### Out of Scope
- Performance testing / load testing (requires separate infrastructure)
- Security penetration testing (hire external security firm)
- Snapshot testing for UI (low value given LiveView tests)
- Mutation testing (too expensive for current scale)

## Affected Areas

### New Files
- `test/fixtures/whatsapp/` - webhook fixtures
- `test/alethea_web/e2e/` - E2E test directory
- `test/support/fakes/fake_llm.ex` - mock LLM
- `test/support/fakes/fake_roberta.ex` - mock RoBERTa
- `test/support/fakes/fake_vault.ex` - mock vault for chaos testing
- `test/support/alethea_jobs_case.ex` - job test helpers
- `test/alethea/ai/phi_worker_test.exs`
- `test/alethea/ai/roberta_worker_test.exs`
- `test/alethea/ai/guided_conversation_chain_test.exs`
- `test/alethea/encryption/patient_vault_test.exs`
- `test/alethea/encryption/professional_kek_test.exs`
- `test/alethea_web/controllers/whatsapp_webhook_controller_test.exs`
- `docs/api/swagger.json` - API documentation

### Modified Files
- `mix.exs` - add Wallaby, open_api_spex dependencies
- `config/test.exs` - Wallaby, OpenAPI config
- `config/config.exs` - OpenAPI config
- `test/test_helper.exs` - Wallaby setup
- `test/support/conn_case.ex` - update for Wallaby
- `lib/alethea_web/controllers/whatsapp_webhook_controller.ex` - add spec
- `lib/alethea_web/controllers/health_controller.ex` - add spec
- `lib/alethea_web/router.ex` - mount Swagger UI
- All job test files refactored to use new helper

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| E2E tests flaky in CI (timing issues) | High | Low | Use explicit waits; retry failed tests once |
| Wallaby setup complex for headless Chrome | Medium | Medium | Document setup; use Playwright as fallback |
| Mocking AI services hides real bugs | Medium | Medium | Contract tests ensure mock matches real API |
| API docs drift from implementation | Medium | Medium | CI check for swagger.json generation |
| Chaos tests cause test suite slowness | Low | Low | Run chaos tests separately (`mix test.chaos`) |

## Rollback Plan

### WhatsApp Contract Tests
- No rollback needed (tests only)
- Fixtures can be removed: `rm -rf test/fixtures/whatsapp/`

### E2E Suite
- Remove Wallaby dependency from mix.exs
- Delete `test/alethea_web/e2e/` directory
- Revert `test/test_helper.exs` and `test/support/conn_case.ex`

### AI Service Mocks
- Replace FakeLLM with real calls in tests (may slow tests)
- Delete `test/support/fakes/` directory

### Oban Test Utilities
- Delete `test/support/alethea_jobs_case.ex`
- Revert job test files to original patterns (manual changes)

### API Documentation
- Remove OpenAPI dependency from mix.exs
- Remove `/api/docs` route from router.ex
- Delete `priv/static/swagger.json`

### Chaos Testing
- Delete chaos test files
- Keep real encryption tests

## Success Criteria

### WhatsApp Contract Tests
- [ ] All webhook payload variants tested
- [ ] Signature verification tests cover valid/invalid/expired cases
- [ ] Rate limiting tests verify 429 response after threshold
- [ ] Fixtures used in both unit and integration tests

### E2E Test Suite
- [ ] Login flow passes in headless Chrome
- [ ] Patient search returns results within 2 seconds
- [ ] Dashboard renders without console errors
- [ ] CI pipeline runs E2E tests on every PR
- [ ] Tests retry once on failure (reduces flakiness)

### AI Service Mocks
- [ ] FakeLLM returns responses matching expected format
- [ ] All AI tests run in <10 seconds (no real API calls)
- [ ] Mock can be swapped for real service via config
- [ ] Contract tests verify response structure

### Oban Job Testing
- [ ] All job tests use `Alethea.Jobs.Case` helper
- [ ] Job chain integration tests verify full pipeline
- [ ] No tests directly manipulate Oban tables

### API Documentation
- [ ] Swagger UI accessible at `/api/docs`
- [ ] All webhook endpoints documented with examples
- [ ] CI verifies swagger.json matches code
- [ ] Docs generated from code annotations (not manual)

### Chaos Testing
- [ ] Encryption roundtrip tests pass
- [ ] Tampered ciphertext raises error (not silent)
- [ ] Key rotation tests verify data still accessible after rotation
- [ ] Large message tests pass for 10KB and 100KB payloads

---

**Status**: PROPOSED  
**Author**: SDD Executor  
**Created**: 2026-06-03  
**Complexity Average**: 2.6/5  
**Related Exploration**: Section 2 (Integration Gaps), Section 3 (Testing Gaps)