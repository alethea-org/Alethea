# 453 Paddle billing (technical slices)

Objective: professionals can pay a Paddle Billing subscription and only entitled professionals reach the clinical workspace. Branch `feat/453-paddle-billing`. Delivery: ask-on-risk. Runner: `mix test` / `mix precommit`.

## Specs

- S1 (#500): `POST /webhooks/paddle` verifies `Paddle-Signature` HMAC (401 + nothing enqueued on failure), fast-acks 200, processes the verified payload in Oban, links to the professional via `custom_data` (first event) or stored Paddle ids, persists status, price, period end. Verified malformed payload → ack-and-drop. Billing disabled when Paddle is not configured or `DEMO_SYNTHETIC_DATA` is on. Only professional email and Alethea id go to Paddle.
- S2 (#501): events `subscription.created`, `activated`, `updated`, `past_due`, `paused`, `canceled`, `transaction.completed`. Same `event_id` twice → applied once. Older `occurred_at` after newer → no rollback. Every state change writes an audit log entry.
- S3 (#502): `Billing.entitled?/1`: `trialing`/`active`, `past_due` (Paddle dunning), `canceled` with future period end; always true when billing disabled. Plug + `on_mount` redirect non-entitled professionals from the workspace to `/billing`. `/billing` reachable and logout possible while lapsed.
- S4 (#503): `/billing` lists configured price ids with localized price (Paddle.js PricePreview), opens overlay checkout with `locale: es`, email and `custom_data.professional_id`; shows "processing" after checkout until the webhook lands; unlocks via PubSub. Phone-width layout.
- S5 (#504): `/billing` shows plan, status, next billing / access-end date; customer portal link for professionals with a Paddle customer.

Assumption: `past_due` is entitled for as long as Paddle keeps the status (Paddle cancels when dunning ends).

## Tasks

- T1 S1+S2 webhook ingest, Billing context, idempotency, ordering, audit — inline — done (13 webhook tests; mutation check: ordering/signature/idempotency off each fail tests)
- T2 S3 gate + /billing — inline — done
- T3 S4+S5 checkout, status, portal — inline — done (11 gate/billing tests; Paddle.js overlay not exercisable in tests)

## Log

- L1 (2026-11-20) "me cierra, pero yo lo que necesito ahora es terminar todo lo técnico, no lo humano, o sea que se pueda pagar y todo, después vemos lo legal. Y para eso necesito que hagas todo vos solo, todo lo que es código. Después vamos con lo terminos etc etc"
- L2 Tickets published: #500-#506 technical/decision slices, #507 legal; implementing #500-#504.
- L3 Tests written after code (not RED-first); compensated with mutation checks. Removing only the gate plug keeps tests green because the on_mount hook also gates the dead render (two layers).
- L4 `mix precommit`: 2929 passed, 5 skipped, no new warnings. Risk: item 2 (auth gate, webhook signature).
- L5 Independent verifier: S1-S5 PASS, no blockers. D1 (late event of abandoned sub takes over row), D2 (browser-set custom_data could relink another professional), N1 (transaction-first blocks earlier activation). Fixed in one batch: server-issued link token in custom_data, only a new active/trialing subscription replaces the stored one, transactions never create rows. 3 regression tests fail on old code, pass on fix. Full suite 2931/2932; the one failure is ReviewTest (E-O-R-C #365), flaky: 5/5 green in isolation with and without the change.
- L6 Accepted as-is: N3 missing PADDLE_WEBHOOK_SECRET in prod disables billing (fail-open, per S1); N4 open socket keeps working after lapse until next mount.
