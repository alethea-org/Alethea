# Feature: Handle Trigger activo delivery failures (#445)

Delivery failures of a Trigger activo use the existing dead-letter path, the firing is shown as "not delivered" in the history, and after 3 consecutive failures the trigger is paused. A successful delivery resets the counter.

## Specs

- S1: Delivery failures of a Trigger activo use the existing dead-letter path: when TelegramOutboundWorker exhausts its retry budget (`attempt >= @max_attempts`) for a trigger message, it writes to `foundation_outbound_dead_letters` and broadcasts `{:outbound_dead_letter, ...}` on `"ops:alerts"`.
- S2: A failed delivery marks the firing as not delivered: the associated `TriggerFiring` record has its `status` updated to `"not_delivered"`. In the clinical history LiveView on the Triggers page, the firing is shown as "No entregado" ("not delivered") with a distinct pill and element ID (`#firing-status-#{firing.id}`).
- S3: A delivery failure increments `consecutive_delivery_failures` on the trigger. After 3 consecutive delivery failures, the trigger is automatically paused (`status: "paused_by_delivery_failures"`), its scheduled Oban jobs are cancelled, and a content-free audit log `"trigger_paused_by_delivery_failures"` is recorded.
- S4: A successful delivery (`{:sent, telegram_message_id}` acknowledged by Telegram) resets `consecutive_delivery_failures` on the trigger to 0. A success in between failures resets the count so 3 consecutive failures are required to pause.
- S5: On the Triggers page, the professional sees the pause reason for any trigger with status `"paused_by_delivery_failures"` (status badge "Pausado por fallas de entrega" and an explanatory notice about the 3 consecutive delivery failures). The professional can resume the trigger ("Reanudar"), which resets `consecutive_delivery_failures` to 0, sets status to `"active"`, reschedules the next occurrence, and writes a `"trigger_resumed"` audit log.

## Tasks

- [x] T1: Migration & Schemas (linked S2, S3) · commit 2c74d27
- [x] T2: Delivery Lifecycle Hooks (linked S1, S2, S3, S4) · commit 2faf50a
- [x] T3: LiveView UI & History Tab (linked S2, S5) · commit 6e8acdc
- [x] T4: Verification & Precommit (linked S1, S2, S3, S4, S5)

## Log

- L1: User requested: "Hagamos la Issues [Feature]: Handle Trigger activo delivery failures #445"
- L2: Created migration `20261104134725_add_delivery_failures_to_triggers.exs` adding `consecutive_delivery_failures` to `triggers` and updating check constraint on `trigger_firings` to allow `status = 'not_delivered'`. Updated schemas `Trigger` and `TriggerFiring` (commit 2c74d27).
- L3: Implemented `Triggers.handle_delivery_failure/1` and `Triggers.handle_delivery_success/1`, wired through `TelegramOutboundWorker.record_delivery/3`. Pauses trigger and cancels Oban jobs on 3 consecutive failures, resets counter on success or resume (commit 2faf50a).
- L4: Updated `TriggersLive.Index` to render "No entregado" pill for not_delivered firings, "Pausado por fallas de entrega" badge with reason notice, and resume button (commit 6e8acdc).
- L5: Verified all tests, ran `mix precommit`: 2653 passed (6 doctests, 2647 tests), 0 failures.
- L6: Applied advisory review improvements (commit cea7c63): added `consecutive_delivery_failures` to `validate_required`, made `handle_delivery_failure/1` strictly idempotent on `TriggerFiring` status, and added error logging in `TelegramOutboundWorker.record_delivery/3`. Mix precommit: 2653 passed, 0 failures.
