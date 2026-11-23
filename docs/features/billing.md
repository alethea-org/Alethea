# Billing (Paddle)

Professionals pay a recurring subscription through Paddle Billing, which acts as Merchant of Record. Spec: #453. Slices: #500–#504.

## How access works

- `Alethea.Billing.entitled?/1` is the only question the app asks.
- A professional is entitled when their subscription is `trialing`, `active` or `past_due`, or `canceled` while the paid period is still running.
- Paddle keeps a subscription `past_due` while it retries a failed payment. It cancels the subscription when the retries run out.
- Professionals who are not entitled are redirected from the clinical workspace to `/billing`. They can still log in, see their status, pay and log out.
- Subscription state changes only through verified Paddle webhooks. Completing checkout in the browser only shows a "processing" state until the webhook arrives.
- Only the professional's email and Alethea id are sent to Paddle.

## Webhook

`POST /webhooks/paddle`:

1. Verifies the `Paddle-Signature` header (HMAC-SHA256 of `ts:raw_body`, timestamp within 5 minutes). If verification fails, it returns 401.
2. Acknowledges with 200 right away.
3. Enqueues `Alethea.Jobs.PaddleEventWorker` on the `billing` queue.

Handled events:

- `subscription.created`
- `subscription.activated`
- `subscription.updated`
- `subscription.trialing`
- `subscription.past_due`
- `subscription.paused`
- `subscription.resumed`
- `subscription.canceled`
- `transaction.completed`, which links ids and never changes the status

Other events are acknowledged and ignored.

Duplicate events (same `event_id`) are applied once. An event older than the last applied one does not roll state back. Every applied change writes a `BILLING_SUBSCRIPTION_CHANGED` audit log entry.

## Configuration

Billing is enforced only when `PADDLE_WEBHOOK_SECRET` is set. Without it, or with `DEMO_SYNTHETIC_DATA=true`, every professional is entitled. This keeps demos and local development working.

| Variable | Value |
| --- | --- |
| `PADDLE_ENVIRONMENT` | `sandbox` (default) or `production` |
| `PADDLE_WEBHOOK_SECRET` | Secret key of the notification destination |
| `PADDLE_API_KEY` | Server-side API key (used for customer portal sessions) |
| `PADDLE_CLIENT_TOKEN` | Client-side token for Paddle.js |
| `PADDLE_PRICE_IDS` | Comma-separated price ids shown on `/billing`, e.g. `pri_01...,pri_02...` |

Once `PADDLE_WEBHOOK_SECRET` is set, the other variables are required and boot fails without them.

## Paddle setup (sandbox first)

1. Create a product with one or more recurring prices. A free trial, if any, is configured on the price. Copy the price ids into `PADDLE_PRICE_IDS`.
2. In **Developer tools → Authentication**, create an API key and a client-side token.
3. In **Developer tools → Notifications**, create a destination:
   - URL: `https://<host>/webhooks/paddle`
   - Events: the subscription events above plus `transaction.completed`
   - Copy its secret key into `PADDLE_WEBHOOK_SECRET`.
4. In **Checkout → Checkout settings**, add the app domain to the approved domains and set a default payment link (Paddle requires one).
5. Set the variables as Fly secrets and deploy:

   ```bash
   fly secrets set -a alethea-prod PADDLE_ENVIRONMENT=sandbox PADDLE_WEBHOOK_SECRET=... \
     PADDLE_API_KEY=... PADDLE_CLIENT_TOKEN=... PADDLE_PRICE_IDS=pri_...
   ```

6. Pay on `/billing` with a Paddle sandbox test card and confirm that the workspace unlocks.

To go live, repeat the setup in the live Paddle account and set `PADDLE_ENVIRONMENT=production`.
