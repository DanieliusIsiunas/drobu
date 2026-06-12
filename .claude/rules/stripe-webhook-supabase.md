# Stripe Webhook + Supabase Fulfillment Gotchas

Learned building the automated license fulfillment (2026-06). Applies to any
future work on `supabase/functions/stripe-webhook` or webhook-shaped services.

## The response-code contract IS the idempotency/alerting mechanism

Stripe treats any non-2xx as retryable (72h exponential backoff) and 2xx as
final. That makes status codes load-bearing, not cosmetic:

- **Permanent no-ops MUST 200** (wrong livemode, plink mismatch, missing
  email, unknown event type, `payment_status: 'unpaid'` on
  `checkout.session.completed`). A 500 on a permanent condition retries a
  no-op for 72h and pushes the endpoint toward Stripe's auto-disable — which
  then silently kills ALL fulfillment.
- **Retryable failures MUST 500** (pool empty, DB error, SMTP failure,
  `email_sent_at` mark failure after a successful send). Stripe's retry queue
  is the recovery mechanism; acking 200 on a failed vend permanently strands
  a paying customer with no signal.
- A misconfig that 200-no-ops live events (e.g. a typo'd `EXPECTED_LIVEMODE`)
  is the worst failure shape: green monitors, no retries, no keys. Strict
  boot-time env validation (throw on anything but exact `"true"`/`"false"`)
  turns it into a loud boot failure instead.

## Fulfill on payment_status, never on event type

`checkout.session.completed` fires with `payment_status: 'unpaid'` for
delayed payment methods (bank debits, vouchers); the later
`checkout.session.async_payment_succeeded` carries the same session id with
`paid`. Handle BOTH events, gate vending on `payment_status != 'unpaid'`,
and key idempotency on the **session id** (the two events have different
event ids — event-id dedup alone double-fulfills).

## Exactly-once vend from a pool: three-layer Postgres pattern

1. Readback first: `SELECT ... WHERE stripe_session_id = $1` → return the
   existing row (retries get the same key).
2. Claim: `UPDATE ... WHERE id = (SELECT id ... WHERE claimed_at IS NULL
   ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING *` under a UNIQUE
   constraint on the session id.
3. Catch `unique_violation` (concurrent winner committed first) → re-SELECT
   and return the winner's row. The plpgsql `begin/exception` block is an
   implicit savepoint: the loser's UPDATE rolls back, its row stays unclaimed.

Verified live: the loser blocks on the winner's in-doubt index entry, the
violation fires post-commit, and the re-SELECT under READ COMMITTED sees the
winner's row. Worst case (1-row pool, concurrent claims) degrades to a
spurious "pool empty" 500 that the retry converges. No interleaving burns two
keys for one session.

## Supabase grants: don't rely on platform default privileges

`REVOKE ... FROM PUBLIC, anon, authenticated` on SECURITY DEFINER functions
works on hosted Supabase only because the platform's default privileges
granted `service_role` an explicit EXECUTE at creation. Add explicit
`GRANT EXECUTE ... TO service_role` anyway — a migration must not depend on
platform bootstrap config. And verify with `SET ROLE service_role` in the
local DB: **superuser psql tests bypass ACLs entirely** and prove nothing
about grants.

## supabase-js rpc() resolves {data, error} — it does not throw

Every wrapper around `supabase.rpc(...)` must translate `error` into a throw
explicitly, or DB failures flow through as successes and the 500 path never
engages. RPCs that should be loud on no-op (e.g. `mark_email_sent` on an
unknown session id) need an explicit `IF NOT FOUND THEN RAISE` — a SQL
UPDATE matching zero rows succeeds silently.

## Edge Function SMTP: port 465 only, bound the whole send

Supabase Edge Functions block outbound 25 and 587 — `smtp.hostinger.com:465`
implicit TLS (`secure: true`) is the only SMTP path. nodemailer's
`socketTimeout` is per SMTP command, not per send; a slow server stacks
commands past Stripe's delivery window. Wrap `sendMail` in a hard deadline
(`Promise.race`-style) so the handler 500s deterministically and the
idempotent retry re-attempts.

## The delivery-failure state nothing else can see

Function healthy + pool ok + Stripe endpoint enabled does NOT mean customers
get keys: SMTP can fail while everything looks green. Track
claimed-but-never-emailed rows (`claimed_at < now() - 30min AND
email_sent_at IS NULL`) and surface them on the health route as a boolean —
the monitor reds on it. Likewise, the only detector for a Stripe-side
disabled/deleted endpoint is asking Stripe's API (restricted read-only key);
no amount of self-health-checking sees absent deliveries.
