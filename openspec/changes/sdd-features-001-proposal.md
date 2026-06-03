# SDD Proposal: New Features - Dashboard, Notifications & Reporting

## Change ID
`sdd-features-001`

## Change Name
New Features for Dashboard, Notifications, and Advanced Reporting

## Intent
The Alethea application currently has a basic dashboard with minimal real-time capabilities, no in-app notification system, and limited reporting features. This proposal outlines high-value feature additions that improve therapist productivity, patient monitoring, and clinical insights. The goal is to deliver incremental features with moderate complexity (2-3/5) that can be shipped independently.

## Scope

### In-Scope Features

#### 1. Emotion Trend Chart (Complexity: 2/5)
- Add 7-day emotion trend visualization to patient detail view
- SVG-based bar chart showing joy, sadness, anger, fear, neutral scores over time
- Color-coded bars with legend
- Data source: existing `EmotionAnalysis` records aggregated by date

#### 2. In-App Notification Center (Complexity: 3/5)
- LiveView component showing notification history
- Real-time updates via Phoenix.PubSub on `crisis:alerts` channel
- Severity levels: info, warning, critical
- Mark as read/unread functionality
- Link to relevant patient record

#### 3. Advanced Patient Search (Complexity: 2/5)
- Live search with debounced queries against patient aliases
- Filter chips for status (active, needs_attention, archived)
- Sort options: urgent_intervention, last_activity, alias
- Phoenix.LiveView form with `phx-change` for real-time filtering

#### 4. Structured Weekly Report (Complexity: 3/5)
- Extend `Summary` schema with structured fields:
  - `anxiety_score` (float, 0-1)
  - `social_score` (float, 0-1)
  - `emotional_range` (map of label → count)
  - `crisis_events` (integer)
  - `session_count` (integer)
- Add structured JSON output to `WeeklySummaryChain`
- Update `lib/alethea/reports/weekly_summary_chain.ex`

#### 5. Session Reminder WhatsApp Messages (Complexity: 2/5)
- Oban-scheduled messages 24h before scheduled sessions
- New `SessionReminderWorker` using existing `Whatsapp.Client`
- Template: "Hi {patient_name}, your session with {therapist_name} is scheduled for tomorrow at {time}. Reply STOP to cancel."

### Out of Scope
- Custom report builder (Complexity 5/5 - future work)
- Practice-wide analytics dashboard
- Patient-facing mobile app
- Media message handling (audio/image)
- Trend escalation detection algorithm

## Affected Areas

### New Files
- `lib/alethea_web/live/dashboard_live/components/emotion_chart.ex` - SVG chart component
- `lib/alethea_web/live/dashboard_live/components/notification_center.ex` - Notification list component
- `lib/alethea_web/live/dashboard_live/components/patient_search.ex` - Search/filter component
- `lib/alethea_jobs/session_reminder_worker.ex` - Oban worker for reminders

### Modified Files
- `priv/repo/migrations/XXXX_add_summary_structured_fields.exs` - New migration for Summary schema changes
- `lib/alethea/reports/summary.ex` - Add structured fields to schema
- `lib/alethea/reports/weekly_summary_chain.ex` - Output structured JSON
- `lib/alethea/dashboard_live.ex` - Mount notification subscription, add search assigns
- `lib/alethea/dashboard_live.html.heex` - Add chart, notification center, search components
- `assets/js/app.js` - Update LiveView socket if needed for PubSub subscriptions

### Unchanged (for now)
- `WhatsappWebhookController` - No changes to webhook handling
- `ProcessMessageWorker` - No changes to clinical pipeline
- Encryption modules - No changes to data-at-rest encryption

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Notification center overwhelms server with subscriptions | Medium | Medium | Limit subscription to active dashboard viewers only |
| Weekly report structured fields break existing reports | Low | High | Add new fields as nullable, maintain backward compatibility |
| WhatsApp API rate limits affect reminder delivery | Medium | Low | Implement retry queue in `Whatsapp.Client` |
| SVG chart performance with large datasets | Low | Low | Paginate emotion analysis queries, limit to 7 days |
| Search query performance degrades with many patients | Medium | Low | Add index on `patients.alias`, debounce input by 300ms |

## Rollback Plan

### Emotion Chart & Patient Search
- Feature flagged via `Application.get_env(:alethea, :features)[:emotion_chart]`
- Set to `false` to disable without code changes
- Full rollback: revert template changes only

### Notification Center
- Remove PubSub.subscribe calls from mount
- Remove component from template
- Database migration is non-destructive (notification records can remain)

### Weekly Report Structured Fields
- Migration is additive (nullable columns)
- Rollback: no action needed, applications handle NULL gracefully
- If needed: `ALTER TABLE summaries DROP COLUMN IF EXISTS anxiety_score` etc.

### Session Reminder Worker
- Set `enabled: false` in Oban config
- Cancel pending jobs: `Oban.cancel_job(job_id)` for all pending reminder jobs
- No database changes

## Success Criteria

### Emotion Trend Chart
- [ ] Chart renders within 500ms for patients with up to 500 EmotionAnalysis records
- [ ] 7-day window is configurable via URL param
- [ ] Empty state shown when patient has no emotion analysis data
- [ ] Color legend matches existing mood signal badges

### In-App Notification Center
- [ ] New crisis alerts appear within 2 seconds for connected clients
- [ ] Notification persists in database across sessions
- [ ] Mark-as-read updates immediately on UI without page refresh
- [ ] Maximum 100 notifications shown (pagination for older)

### Advanced Patient Search
- [ ] Search results appear within 300ms of keystroke (debounced)
- [ ] Filters combine correctly (AND logic)
- [ ] Empty search returns full patient list sorted by urgent_intervention
- [ ] No XSS vulnerabilities in patient alias display

### Structured Weekly Report
- [ ] All new fields populated for new summaries after migration
- [ ] Existing summaries have NULL for new fields (graceful handling)
- [ ] JSON output matches schema definition
- [ ] Unit tests cover all new struct fields

### Session Reminder Worker
- [ ] Worker executes within 1 minute of scheduled time
- [ ] WhatsApp message delivered successfully (verified via delivery status)
- [ ] Failed sends retry up to 3 times with exponential backoff
- [ ] Worker logs success/failure to audit log

---

**Status**: PROPOSED  
**Author**: SDD Executor  
**Created**: 2026-06-03  
**Complexity Average**: 2.4/5  
**Related Exploration**: Section 1 (New Features Analysis)