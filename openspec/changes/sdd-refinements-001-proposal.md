# SDD Proposal: Code Refinements - Auth, Pipeline & AI Improvements

## Change ID
`sdd-refinements-001`

## Change Name
Code Refinements: Auth Flow, Clinical Pipeline, and AI Worker Improvements

## Intent
The Alethea codebase has several areas with partial implementations, missing edge-case handling, and technical debt that reduce reliability and maintainability. This proposal addresses targeted refinements that improve security (auth flow), resilience (clinical pipeline), and efficiency (AI workers) without major architectural changes.

## Scope

### In-Scope Refinements

#### 1. Password Reset Flow (Complexity: 3/5)
**Current State**: No password reset functionality exists.

**Proposed Changes**:
- Add `password_reset_token` and `token_expires_at` fields to `Professional` schema
- New `RegistrationController.reset_request/2` for "forgot password" form
- New `RegistrationController.reset_password/2` for token submission
- Email delivery via existing Swoosh configuration
- Secure token: 32-byte random, Base64URL encoded, 1-hour expiry

**Files Affected**:
- `priv/repo/migrations/XXXX_add_password_reset_fields.exs`
- `lib/alethea/accounts/professional.ex` - schema changes
- `lib/alethea/accounts.ex` - `generate_reset_token/1`, `reset_password/2`
- `lib/alethea_web/controllers/registration_controller.ex` - new actions
- `lib/alethea_web/controllers/professional_auth.ex` - no changes needed
- `lib/alethea_web/router.ex` - new routes
- `priv/repo/seeds.exs` - ensure admin can trigger resets (for testing)

#### 2. Remember Me Cookie (Complexity: 2/5)
**Current State**: Users must log in every session.

**Proposed Changes**:
- Add `remember_me_token` field to `Professional` schema
- `SessionController` generates signed Phoenix.Token on login with "remember me"
- Cookie set with 30-day expiry, HttpOnly, Secure flags
- `ProfessionalAuth` plug checks token on mount if no session
- Token rotation on each use (prevents session fixation)

**Files Affected**:
- `priv/repo/migrations/XXXX_add_remember_me_token.exs`
- `lib/alethea/accounts/professional.ex`
- `lib/alethea/accounts.ex` - `generate_remember_token/1`, `verify_remember_token/1`
- `lib/alethea_web/controllers/session_controller.ex`
- `lib/alethea_web/plugs/professional_auth.ex` - update `fetch_current_professional/2`

#### 3. Batch RoBERTa Processing (Complexity: 2/5)
**Current State**: `analyze_batch/1` exists in RoBERTaWorker but is unused.

**Proposed Changes**:
- New `ScheduledEmotionAnalysisWorker` runs daily at 02:00 UTC
- Queries messages without emotion analysis in batches of 100
- Calls `RoBERTaWorker.analyze_batch/1`
- Updates `emotion_analyses` table with results
- Idempotent: skips messages that already have analysis

**Files Affected**:
- `lib/alethea_jobs/scheduled_emotion_analysis_worker.ex` - new Oban worker
- `lib/alethea/ai/roberta_worker.ex` - ensure batch function is optimal
- `config/runtime.exs` - add schedule config
- `config/config.exs` - add Oban producer config

#### 4. Session Recovery Logic (Complexity: 3/5)
**Current State**: Sessions may fragment when patient sends messages after timeout but before `SessionTimeoutWorker` executes.

**Proposed Changes**:
- Modify `SessionManager.handle_continue(:check_timeouts)` to:
  - Query sessions last activity > 25 minutes ago (5-minute buffer before timeout)
  - Mark as "interrupted" rather than "closed"
  - Attempt to merge with any open session within 2-hour window
- Add `merged_from_session_id` field to `Session` schema
- UI: show "merged" indicator on session timeline

**Files Affected**:
- `priv/repo/migrations/XXXX_add_session_merge_fields.exs`
- `lib/alethea/clinical/session.ex` - schema changes
- `lib/alethea/clinical/session_manager.ex` - update timeout handling
- `lib/alethea/clinical/session_timeout_worker.ex` - modify merge logic
- `lib/alethea_web/live/patient_live/chat_view.exheex` - display merge indicator

#### 5. Response Diversity for AI (Complexity: 3/5)
**Current State**: AI responses may repeat identical phrases for similar inputs.

**Proposed Changes**:
- Add `temperature` and `top_p` parameters to `PhiWorker` config
- Implement response cache with 5-minute TTL keyed on sanitized message hash
- Add "diversity boost" flag that increases temperature slightly for follow-up messages
- Log repetition instances for monitoring

**Files Affected**:
- `lib/alethea/ai/phi_worker.ex` - update LLM config
- `lib/alethea/ai/response_cache.ex` - new module for caching
- `lib/alethea/ai/guided_conversation_chain.ex` - use cache
- `config/runtime.exs` - temperature config
- `lib/alethea_jobs/phi_worker.ex` - update worker config

### Out of Scope
- Full JWT/API token authentication (separate auth service work)
- Two-factor authentication (HIPAA compliance - future work)
- HSM integration for key management
- Media message handling (audio/image)
- Multi-tenant architecture

## Affected Areas

### New Files
- `lib/alethea/ai/response_cache.ex` - ETS-based response cache
- `lib/alethea_jobs/scheduled_emotion_analysis_worker.ex` - batch analysis scheduler

### Modified Files
- `priv/repo/migrations/XXXX_add_password_reset_fields.exs`
- `priv/repo/migrations/XXXX_add_remember_me_token.exs`
- `priv/repo/migrations/XXXX_add_session_merge_fields.exs`
- `lib/alethea/accounts/professional.ex`
- `lib/alethea/accounts.ex`
- `lib/alethea/clinical/session.ex`
- `lib/alethea/clinical/session_manager.ex`
- `lib/alethea/ai/phi_worker.ex`
- `lib/alethea/ai/roberta_worker.ex`
- `lib/alethea/ai/guided_conversation_chain.ex`
- `lib/alethea_web/controllers/session_controller.ex`
- `lib/alethea_web/controllers/registration_controller.ex`
- `lib/alethea_web/plugs/professional_auth.ex`
- `lib/alethea_web/router.ex`
- `config/runtime.exs`
- `config/config.exs`

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Password reset tokens can be guessed | Low | High | Use `:crypto.strong_rand_bytes/1`, rate limit reset requests |
| Remember me token theft (XSS) | Medium | High | HttpOnly, Secure cookie flags; token rotation on use |
| Batch analysis overloads GPU/CPU | Medium | Medium | Limit batch size, run during off-peak hours |
| Session merge causes data inconsistency | Medium | Medium | Use Ecto multi-step transactions; rollback on failure |
| Response cache grows unbounded | Medium | Low | TTL of 5 minutes, max 10,000 entries with LRU eviction |
| Remember me breaks existing sessions | Low | Medium | Feature flag; test thoroughly before enabling |

## Rollback Plan

### Password Reset & Remember Me
- Revert migrations: `mix ecto.rollback` for each migration
- Revert controller changes
- Remove new routes
- Users may need to re-login

### Batch RoBERTa
- Disable worker in config: `enabled: false`
- Delete scheduled jobs: use `Oban.cancel_job/1` for pending
- No migration rollback needed (data remains)

### Session Recovery
- Migration is additive (nullable `merged_from_session_id`)
- Revert to old timeout behavior in `SessionManager`
- Existing sessions remain with current state

### Response Diversity
- Disable via config: `temperature: 0.0` (disables diversity boost)
- Response cache can be cleared: `ETS.delete_all_objects(ResponseCache)`
- No database changes

## Success Criteria

### Password Reset
- [ ] Reset email sent within 30 seconds of form submission
- [ ] Token expires after 1 hour (cannot be used after)
- [ ] Invalid/expired token shows clear error message
- [ ] Password change requires confirmation matching new password
- [ ] Rate limit: max 3 reset requests per hour per email

### Remember Me
- [ ] Cookie persists across browser restart
- [ ] Token rotated on each successful authentication
- [ ] Old token invalidated after use (no session fixation)
- [ ] Logout clears remember_me cookie

### Batch RoBERTa
- [ ] Daily worker executes within 2-hour window
- [ ] Processes up to 1000 messages per run without timeout
- [ ] Idempotent: running twice produces same results
- [ ] Logs batch size and duration for monitoring

### Session Recovery
- [ ] Interrupted sessions merge correctly within 2-hour window
- [ ] No duplicate sessions for same patient
- [ ] UI shows accurate session count including merged
- [ ] Ecto transactions ensure consistency

### Response Diversity
- [ ] Cache hit rate > 30% for repeated queries
- [ ] Temperature variation produces visibly different responses
- [ ] No cached responses served for crisis-related messages
- [ ] Memory usage stable over 24 hours (no leak)

---

**Status**: PROPOSED  
**Author**: SDD Executor  
**Created**: 2026-06-03  
**Complexity Average**: 2.6/5  
**Related Exploration**: Section 2.1 (Auth Flow), 2.2 (Clinical Pipeline), 2.4 (AI Workers)