// Pure request handler for the license-fulfillment webhook.
//
// Every effect is injected via HandlerDeps so `deno test` exercises the full
// routing + gate + vend + email flow with constructed Requests. index.ts is
// the only file that touches Stripe/Supabase/SMTP for real.
//
// Response-code contract (the load-bearing table — wrong codes either strand
// customers or trip Stripe's endpoint auto-disable):
//   bad signature ............................ 400
//   permanent no-ops (unpaid gate, livemode/plink mismatch, missing email,
//     async_payment_failed, unknown event, already-emailed replay) ... 200
//   retryable failures (pool empty, claim error, send failure,
//     mark-email-sent failure) ............... 500  (Stripe retries ≤72h;
//     the idempotent claim makes every retry safe)
//   GET <fn>/health .......................... 200 + pool bucket, 500 if the
//     depth probe itself fails (a DB outage must read as unreachable)
//   anything else ............................ 404/405
//
// Responses never carry key material — Stripe stores webhook response bodies.

export interface VendResult {
  key: string;
  payloadHex: string;
  emailSentAt: string | null;
}

export interface SessionLike {
  id: string;
  livemode: boolean;
  payment_status: string;
  payment_link: string | null;
  amount_total: number | null;
  currency: string | null;
  customer_details: { email: string | null } | null;
}

export interface EventLike {
  id: string;
  type: string;
  data: { object: SessionLike };
}

export interface HandlerConfig {
  expectedLivemode: boolean;
  // null/empty pin downgrades the plink gate to a log-only warning — local
  // `stripe trigger` fixtures carry payment_link: null, so a hard pin would
  // make local end-to-end testing impossible.
  paymentLinkId: string | null;
  // Log-only floor in minor units; adaptive pricing varies currency, so
  // amounts never block fulfillment.
  amountFloor: number | null;
}

export interface HandlerDeps {
  // Throws on bad/missing signature.
  verifyEvent(rawBody: string, signature: string | null): Promise<EventLike>;
  claimKey(
    sessionId: string,
    email: string,
    amount: number | null,
    currency: string | null,
  ): Promise<VendResult>;
  markEmailSent(sessionId: string): Promise<void>;
  sendMail(to: string, key: string): Promise<void>;
  poolDepth(): Promise<"ok" | "low" | "empty">;
  config: HandlerConfig;
  log(line: string): void;
}

const FULFILL_EVENTS = [
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
];

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// The function sees paths like /stripe-webhook and /stripe-webhook/health
// when deployed (and the same shape under `supabase functions serve`).
function route(pathname: string): "webhook" | "health" | "unknown" {
  const p = pathname.replace(/^\/stripe-webhook/, "").replace(/\/+$/, "");
  if (p === "" || p === "/") return "webhook";
  if (p === "/health") return "health";
  return "unknown";
}

export async function handleRequest(
  req: Request,
  deps: HandlerDeps,
): Promise<Response> {
  const r = route(new URL(req.url).pathname);

  if (r === "unknown") return json(404, { error: "not found" });

  if (r === "health") {
    if (req.method !== "GET") return json(405, { error: "method not allowed" });
    try {
      const pool = await deps.poolDepth();
      return json(200, { ok: true, pool });
    } catch (e) {
      // A DB outage must read as unreachable to the monitor, never healthy.
      deps.log(`StripeWebhook: health pool_depth failed: ${e}`);
      return json(500, { ok: false });
    }
  }

  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  const rawBody = await req.text();
  let event: EventLike;
  try {
    event = await deps.verifyEvent(
      rawBody,
      req.headers.get("stripe-signature"),
    );
  } catch (e) {
    deps.log(`StripeWebhook: signature verification failed: ${e}`);
    return json(400, { error: "invalid signature" });
  }

  if (event.type === "checkout.session.async_payment_failed") {
    deps.log(
      `StripeWebhook: async payment failed for session ${event.data.object.id} (event ${event.id}) — no vend; Stripe notifies the customer`,
    );
    return json(200, { received: true });
  }

  if (!FULFILL_EVENTS.includes(event.type)) {
    deps.log(`StripeWebhook: ignoring event type ${event.type} (${event.id})`);
    return json(200, { received: true });
  }

  const session = event.data.object;
  const tag = `session ${session.id}, event ${event.id}`;

  if (session.livemode !== deps.config.expectedLivemode) {
    deps.log(
      `StripeWebhook: livemode ${session.livemode} != expected ${deps.config.expectedLivemode} — no vend (${tag})`,
    );
    return json(200, { received: true });
  }

  if (deps.config.paymentLinkId) {
    if (session.payment_link !== deps.config.paymentLinkId) {
      deps.log(
        `StripeWebhook: PAYMENT LINK MISMATCH — session came from ${session.payment_link}, expected pin — no vend; if a second Payment Link was created deliberately, update the PAYMENT_LINK_ID secret (${tag})`,
      );
      return json(200, { received: true });
    }
  } else {
    deps.log(
      `StripeWebhook: payment_link pin unset — provenance gate is log-only (${tag})`,
    );
  }

  const email = session.customer_details?.email ?? null;
  if (!email) {
    deps.log(
      `StripeWebhook: NO CUSTOMER EMAIL on paid session — cannot fulfill automatically; vend manually from the Stripe dashboard (${tag})`,
    );
    return json(200, { received: true });
  }

  if (session.payment_status === "unpaid") {
    // Normal for delayed payment methods: completed arrives unpaid, the
    // later async_payment_succeeded fulfills.
    deps.log(`StripeWebhook: payment_status unpaid — deferring (${tag})`);
    return json(200, { received: true });
  }

  if (
    deps.config.amountFloor !== null &&
    session.amount_total !== null &&
    session.amount_total < deps.config.amountFloor
  ) {
    deps.log(
      `StripeWebhook: AMOUNT BELOW FLOOR — amount_total ${session.amount_total} ${session.currency} < ${deps.config.amountFloor}; vending anyway (log-only sanity signal) (${tag})`,
    );
  }

  let vend: VendResult;
  try {
    vend = await deps.claimKey(
      session.id,
      email,
      session.amount_total,
      session.currency,
    );
  } catch (e) {
    deps.log(`StripeWebhook: claim failed: ${e} (${tag})`);
    return json(500, { error: "vend failed" });
  }
  deps.log(
    `StripeWebhook: claimed key payload_hex=${vend.payloadHex} for ${tag}`,
  );

  if (vend.emailSentAt) {
    deps.log(
      `StripeWebhook: already emailed at ${vend.emailSentAt} — retry acknowledged without re-send (${tag})`,
    );
    return json(200, { received: true });
  }

  try {
    await deps.sendMail(email, vend.key);
  } catch (e) {
    deps.log(`StripeWebhook: email send failed: ${e} (${tag})`);
    return json(500, { error: "email failed" });
  }

  try {
    await deps.markEmailSent(session.id);
  } catch (e) {
    // The mail went out but the stamp didn't land. 500 so Stripe retries:
    // the retry re-claims the same key and re-sends — one duplicate
    // identical email in this narrow window is harmless; a row stuck
    // claimed-but-unmarked would misread as "never emailed" forever.
    deps.log(`StripeWebhook: mark_email_sent failed after send: ${e} (${tag})`);
    return json(500, { error: "mark failed" });
  }

  deps.log(`StripeWebhook: fulfilled ${tag}`);
  return json(200, { received: true });
}
