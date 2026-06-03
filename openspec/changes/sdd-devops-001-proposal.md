# SDD Proposal: DevOps - Infrastructure, Observability & Deployment

## Change ID
`sdd-devops-001`

## Change Name
DevOps Enhancements: Deployment Pipeline, Observability, and Infrastructure Reliability

## Intent
The Alethea application lacks production-grade observability, reliable deployment tooling, and infrastructure monitoring. This proposal addresses critical DevOps improvements that enable reliable deployments, proactive monitoring, and faster incident response. These changes support HIPAA compliance requirements and improve operational efficiency.

## Scope

### In-Scope Improvements

#### 1. Structured Logging with Telemetry (Complexity: 2/5)
**Current State**: Basic `Logger.info/1` calls scattered throughout codebase, no structured events.

**Proposed Changes**:
- Add Telemetry events for all critical operations:
  - `[:alethea, :webhook, :received]` - WhatsApp webhook receipt
  - `[:alethea, :message, :processed]` - Message pipeline completion
  - `[:alethea, :ai, :roberta, :analyzed]` - Emotion analysis completion
  - `[:alethea, :ai, :phi, :response_sent]` - AI response delivery
  - `[:alethea, :session, :started]` / `[:alethea, :session, :ended]`
  - `[:alethea, :crisis, :detected]` - Crisis alert generation
- Add metadata to all events: `professional_id`, `patient_id`, `duration_ms`
- Integrate with existing Logger via Telemetry.LoggerForwarder
- Dashboards in Grafana for key metrics

**Files Affected**:
- `lib/alethea/telemetry.ex` - new module with event definitions and handler setup
- `lib/alethea/jobs/process_message_worker.ex` - emit events
- `lib/alethea/ai/roberta_worker.ex` - emit events
- `lib/alethea/ai/phi_worker.ex` - emit events
- `lib/alethea/clinical/session_manager.ex` - emit events
- `lib/alethea/clinical/crisis_monitor.ex` - emit events
- `config/runtime.exs` - telemetry configuration
- `docker-compose.yml` - add Grafana and Prometheus services
- `Dockerfile` - ensure production image includes telemetry setup

#### 2. Health Check Endpoints (Complexity: 2/5)
**Current State**: No dedicated health check endpoint for load balancer/orchestrator.

**Proposed Changes**:
- Add `/api/health` endpoint returning JSON:
  ```json
  {
    "status": "ok",
    "version": "1.0.0",
    "database": "connected",
    "oban": "connected",
    "whatsapp": "connected"
  }
  ```
- Separate `/api/health/ready` for readiness probe (checks all deps)
- Separate `/api/health/live` for liveness probe (basic check only)
- All checks have 5-second timeout to prevent hanging probes

**Files Affected**:
- `lib/alethea_web/controllers/health_controller.ex` - new controller
- `lib/alethea_web/router.ex` - add health routes (outside auth scope)
- `config/prod.exs` - ensure CowboyOpts configured correctly
- `config/runtime.exs` - health check timeout config

#### 3. Deployment Script Improvements (Complexity: 2/5)
**Current State**: Basic Mix release, no blue-green or canary deployment support.

**Proposed Changes**:
- Create `scripts/deploy.sh` with:
  - Database migration before deploy
  - Rolling update with health check verification
  - Rollback capability: `scripts/rollback.sh <release_version>`
  - Health check polling (10 attempts, 5-second intervals)
- Add `mix release` with version from mix.exs
- Add pre-flight checks: sufficient disk space, memory available

**Files Affected**:
- `scripts/deploy.sh` - new deployment script
- `scripts/rollback.sh` - new rollback script
- `scripts/pre-flight.sh` - new pre-flight checks
- `mix.exs` - add version from git tag
- `.github/workflows/deploy.yml` - GitHub Actions workflow (if using GH Actions)

#### 4. Oban Dashboard for Admin (Complexity: 3/5)
**Current State**: No UI for Oban job monitoring.

**Proposed Changes**:
- Mount Oban Web dashboard at `/admin/oban`
- Protect with admin-only authentication (check `professional.role == :admin`)
- Display: job queue stats, failed jobs, retry queue, scheduled jobs
- Add custom actions: retry failed, cancel scheduled

**Files Affected**:
- `lib/alethea_web/router.ex` - mount Oban Web dashboard
- `lib/alethea_web/plugs/admin_auth.ex` - new plug for admin-only routes
- `config/config.exs` - Oban plugins for Web

#### 5. Database Connection Pool Monitoring (Complexity: 2/5)
**Current State**: No visibility into connection pool health.

**Proposed Changes**:
- Add Telemetry events for pool checkouts/checkins:
  - `[:alethea, :repo, :pool, :checkout]` with duration metadata
  - `[:alethea, :repo, :pool, :checkout_timeout]` for connection delays
- Log warning when >10% of checkouts exceed 100ms
- Add metrics for Prometheus export

**Files Affected**:
- `lib/alethea/repo.ex` - add telemetry in repo callback
- `config/runtime.exs` - pool size configuration for production
- `docker-compose.yml` - add pg_exporter for PostgreSQL metrics

#### 6. Backup Strategy (Complexity: 3/5)
**Current State**: No documented backup procedure.

**Proposed Changes**:
- Document backup strategy in `docs/backup.md`:
  - Full database dump: daily at 03:00 UTC
  - Incremental: every 6 hours
  - Retention: 30 days
  - Test restores quarterly
- Add `scripts/backup.sh` for manual backups
- Add `scripts/restore.sh` for disaster recovery
- Configure `DATABASE_URL` for point-in-time recovery

**Files Affected**:
- `scripts/backup.sh` - new backup script
- `scripts/restore.sh` - new restore script
- `docs/backup.md` - documentation
- `docker-compose.yml` - add backup container (if using Docker)

### Out of Scope
- Kubernetes deployment manifests (separate infrastructure work)
- Full CI/CD pipeline (GitHub Actions already partially configured)
- Multi-region deployment
- Secrets rotation automation
- Chaos engineering / fault injection

## Affected Areas

### New Files
- `lib/alethea/telemetry.ex` - telemetry definitions and handlers
- `lib/alethea_web/controllers/health_controller.ex` - health check controller
- `lib/alethea_web/plugs/admin_auth.ex` - admin authentication plug
- `scripts/deploy.sh` - deployment script
- `scripts/rollback.sh` - rollback script
- `scripts/pre-flight.sh` - pre-flight checks
- `scripts/backup.sh` - database backup script
- `scripts/restore.sh` - disaster recovery script
- `docs/backup.md` - backup documentation
- `docker-compose.yml` - add observability services

### Modified Files
- `lib/alethea/jobs/process_message_worker.ex`
- `lib/alethea/ai/roberta_worker.ex`
- `lib/alethea/ai/phi_worker.ex`
- `lib/alethea/ai/guided_conversation_chain.ex`
- `lib/alethea/clinical/session_manager.ex`
- `lib/alethea/clinical/crisis_monitor.ex`
- `lib/alethea/repo.ex`
- `lib/alethea_web/router.ex`
- `config/runtime.exs`
- `config/prod.exs`
- `config/config.exs`
- `mix.exs`
- `Dockerfile` (if exists)

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Telemetry events cause performance overhead | Low | Low | Async event emission; no blocking in hot path |
| Health checks expose sensitive info | Medium | High | Only expose status, not internal details |
| Oban dashboard access by non-admin | Low | High | Admin plug verification mandatory |
| Backup scripts fail silently | Medium | High | Verify backup on creation; alert on failure |
| Database connection exhaustion from monitoring | Low | High | Pool monitoring is read-only; timeouts enforced |
| Deployment script breaks existing deploys | Medium | High | Test on staging first; maintain rollback path |

## Rollback Plan

### Telemetry
- Remove Telemetry handler in config (events still emitted but ignored)
- No code rollback needed for event emissions
- Disable Grafana dashboards by removing data source

### Health Endpoints
- Remove routes from router.ex
- No migration or database changes

### Deployment Scripts
- Scripts are additive; existing deploy process unaffected
- Remove scripts to rollback

### Oban Dashboard
- Remove from router.ex
- Remove AdminAuth plug
- Users logged out but no data loss

### Backup Strategy
- Scripts are documentation; no runtime effect
- Disable cron jobs to stop scheduled backups

## Success Criteria

### Structured Logging
- [ ] All critical paths emit Telemetry events
- [ ] Events include required metadata (professional_id, duration_ms)
- [ ] Grafana dashboard shows real-time metrics
- [ ] No events cause >1ms overhead in hot path

### Health Checks
- [ ] `/api/health/live` responds in <50ms
- [ ] `/api/health/ready` returns 503 if any dependency unhealthy
- [ ] Load balancer correctly detects unhealthy instances
- [ ] Timeout enforced at 5 seconds

### Deployment Scripts
- [ ] Deploy completes in <10 minutes (including health checks)
- [ ] Rollback completes in <5 minutes
- [ ] Pre-flight checks catch disk/memory issues before deploy
- [ ] Migration runs before new version starts

### Oban Dashboard
- [ ] Admin users can view job stats without errors
- [ ] Non-admin users receive 403 Forbidden
- [ ] Dashboard loads in <2 seconds
- [ ] Failed jobs can be retried from UI

### Database Monitoring
- [ ] Pool checkout duration tracked in metrics
- [ ] Alert fires when >10% checkouts exceed 100ms
- [ ] Prometheus scrapes pool metrics successfully

### Backup Strategy
- [ ] Daily backup completes successfully
- [ ] Backup size tracked for capacity planning
- [ ] Restore tested successfully in non-production
- [ ] Documentation accurate and current

---

**Status**: PROPOSED  
**Author**: SDD Executor  
**Created**: 2026-06-03  
**Complexity Average**: 2.4/5  
**Related Exploration**: Section 3 (Infrastructure Gaps)