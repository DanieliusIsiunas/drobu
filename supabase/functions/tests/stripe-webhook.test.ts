// deno test suite for the stripe-webhook handler.
//
// Run from the repo root:
//   deno test --allow-env --allow-net=none \
//     --config supabase/functions/stripe-webhook/deno.json \
//     supabase/functions/tests/
//
// Signature verification is exercised through the REAL
// stripe.webhooks.constructEventAsync (SubtleCryptoProvider) against headers
// HMAC'd here with Web Crypto — proving the exact verification path index.ts
// uses, not a mock of it. Everything past verification runs through injected
// deps per handler.ts's seam.

import Stripe from "stripe";
import {
  type EventLike,
  handleRequest,
  type HandlerConfig,
  type HandlerDeps,
  type SessionLike,
  type VendResult,
} from "../stripe-webhook/handler.ts";

const SECRET = "whsec_test_secret_for_deno_tests";
const stripe = new Stripe("sk_test_unused");
const cryptoProvider = Stripe.createSubtleCryptoProvider();

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}
function assertEquals<T>(actual: T, expected: T, msg?: string) {
  if (actual !== expected) {
    throw new Error(
      `${msg ?? "assertEquals"}: expected ${expected}, got ${actual}`,
    );
  }
}

async function signHeader(
  body: string,
  secret: string,
  timestamp = Math.floor(Date.now() / 1000),
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    enc.encode(`${timestamp}.${body}`),
  );
  const hex = [...new Uint8Array(sig)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `t=${timestamp},v1=${hex}`;
}

function session(overrides: Partial<SessionLike> = {}): SessionLike {
  return {
    id: "cs_test_abc123",
    livemode: false,
    payment_status: "paid",
    payment_link: "plink_test_1",
    amount_total: 1499,
    currency: "eur",
    customer_details: { email: "customer@example.com" },
    ...overrides,
  };
}

function event(type: string, s: SessionLike): Record<string, unknown> {
  return {
    id: "evt_test_1",
    object: "event",
    type,
    livemode: s.livemode,
    data: { object: { object: "checkout.session", ...s } },
  };
}

interface Calls {
  claims: Array<{
    sessionId: string;
    email: string;
    amount: number | null;
    currency: string | null;
  }>;
  sends: Array<{ to: string; key: string }>;
  marks: string[];
  logs: string[];
}

function makeDeps(opts: {
  vend?: VendResult | Error;
  sendError?: Error;
  markError?: Error;
  pool?: "ok" | "low" | "empty" | Error;
  stuck?: boolean | Error;
  config?: Partial<HandlerConfig>;
} = {}): { deps: HandlerDeps; calls: Calls } {
  const calls: Calls = { claims: [], sends: [], marks: [], logs: [] };
  const deps: HandlerDeps = {
    async verifyEvent(rawBody, signature) {
      if (!signature) throw new Error("missing stripe-signature header");
      const ev = await stripe.webhooks.constructEventAsync(
        rawBody,
        signature,
        SECRET,
        undefined,
        cryptoProvider,
      );
      return ev as unknown as EventLike;
    },
    // deno-lint-ignore require-await
    async claimKey(sessionId, email, amount, currency) {
      calls.claims.push({ sessionId, email, amount, currency });
      const v = opts.vend ??
        { key: "DROBU-testpayload.testsig", payloadHex: "ab01", emailSentAt: null };
      if (v instanceof Error) throw v;
      return v;
    },
    // deno-lint-ignore require-await
    async markEmailSent(sessionId) {
      if (opts.markError) throw opts.markError;
      calls.marks.push(sessionId);
    },
    // deno-lint-ignore require-await
    async sendMail(to, key) {
      if (opts.sendError) throw opts.sendError;
      calls.sends.push({ to, key });
    },
    // deno-lint-ignore require-await
    async poolDepth() {
      const p = opts.pool ?? "ok";
      if (p instanceof Error) throw p;
      return p;
    },
    // deno-lint-ignore require-await
    async stuckVends() {
      const s = opts.stuck ?? false;
      if (s instanceof Error) throw s;
      return s;
    },
    config: {
      expectedLivemode: false, // local-dev shape; fixtures are livemode:false
      paymentLinkId: "plink_test_1",
      amountFloor: 1000,
      ...opts.config,
    },
    log: (line) => calls.logs.push(line),
  };
  return { deps, calls };
}

async function signedPost(
  payload: Record<string, unknown>,
  opts: { timestamp?: number; corrupt?: boolean } = {},
): Promise<Request> {
  const body = JSON.stringify(payload);
  let sig = await signHeader(body, SECRET, opts.timestamp);
  if (opts.corrupt) sig = sig.replace(/v1=.{8}/, "v1=00000000");
  return new Request("http://localhost/stripe-webhook", {
    method: "POST",
    headers: { "stripe-signature": sig },
    body,
  });
}

Deno.test("valid completed+paid event vends, emails, marks, 200", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 1, "one claim");
  assertEquals(calls.claims[0].email, "customer@example.com", "claim email");
  assertEquals(calls.claims[0].amount, 1499, "amount forwarded");
  assertEquals(calls.claims[0].currency, "eur", "currency forwarded");
  assertEquals(calls.sends.length, 1, "one send");
  assert(
    calls.sends[0].key === "DROBU-testpayload.testsig",
    "key passed to mail",
  );
  assertEquals(calls.marks.length, 1, "marked sent");
  const bodyText = await res.text();
  assert(!bodyText.includes("DROBU-"), "response body carries no key");
  assert(
    !calls.logs.some((l) => l.includes("DROBU-")),
    "log breadcrumbs carry no key material",
  );
});

Deno.test("corrupted signature -> 400, claim never called", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session()), {
      corrupt: true,
    }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("timestamp just past the 300s tolerance -> 400", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session()), {
      timestamp: Math.floor(Date.now() / 1000) - 301,
    }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("aged-but-within-tolerance timestamp (-200s) verifies and vends", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session()), {
      timestamp: Math.floor(Date.now() / 1000) - 200,
    }),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 1, "vended");
});

Deno.test("missing signature header -> 400", async () => {
  const { deps, calls } = makeDeps();
  const body = JSON.stringify(event("checkout.session.completed", session()));
  const res = await handleRequest(
    new Request("http://localhost/stripe-webhook", { method: "POST", body }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("completed with payment_status unpaid -> 200, no claim", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event(
        "checkout.session.completed",
        session({ payment_status: "unpaid" }),
      ),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("async_payment_succeeded + paid vends", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event("checkout.session.async_payment_succeeded", session()),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 1, "claimed");
  assertEquals(calls.sends.length, 1, "sent");
  assertEquals(calls.marks.length, 1, "marked sent");
});

Deno.test("async_payment_failed -> 200, no claim", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event("checkout.session.async_payment_failed", session()),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("replay not yet marked sent -> same key re-sent, 200", async () => {
  const { deps, calls } = makeDeps({
    vend: { key: "DROBU-already.claimed", payloadHex: "ab02", emailSentAt: null },
  });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.sends.length, 1, "re-sent");
  assertEquals(calls.sends[0].key, "DROBU-already.claimed", "same key");
});

Deno.test("replay already marked email_sent_at -> 200, NO send", async () => {
  const { deps, calls } = makeDeps({
    vend: {
      key: "DROBU-already.claimed",
      payloadHex: "ab02",
      emailSentAt: "2026-06-11T10:00:00Z",
    },
  });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.sends.length, 0, "no re-send");
  assertEquals(calls.marks.length, 0, "no re-mark");
});

Deno.test("pool empty (claim throws) -> 500", async () => {
  const { deps, calls } = makeDeps({
    vend: new Error("claim_license_key: license pool empty"),
  });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 500, "status");
  assertEquals(calls.sends.length, 0, "no send");
});

Deno.test("email send rejection -> 500 after claim", async () => {
  const { deps, calls } = makeDeps({ sendError: new Error("smtp timeout") });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 500, "status");
  assertEquals(calls.claims.length, 1, "claim happened before send");
  assertEquals(calls.marks.length, 0, "not marked");
});

Deno.test("markEmailSent rejection after successful send -> 500", async () => {
  const { deps, calls } = makeDeps({ markError: new Error("db blip") });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 500, "status");
  assertEquals(calls.sends.length, 1, "mail went out");
});

Deno.test("missing customer email -> 200, no claim, error breadcrumb", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event(
        "checkout.session.completed",
        session({ customer_details: { email: null } }),
      ),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
  assert(
    calls.logs.some((l) => l.includes("NO CUSTOMER EMAIL")),
    "loud breadcrumb",
  );
});

Deno.test("livemode mismatch vs EXPECTED_LIVEMODE -> 200, no claim", async () => {
  const { deps, calls } = makeDeps(); // expects livemode false
  const res = await handleRequest(
    await signedPost(
      event("checkout.session.completed", session({ livemode: true })),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("plink mismatch -> 200, no claim, loud log", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event(
        "checkout.session.completed",
        session({ payment_link: "plink_other" }),
      ),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
  assert(
    calls.logs.some((l) => l.includes("PAYMENT LINK MISMATCH")),
    "loud log",
  );
});

Deno.test("unset plink pin -> log-only warning, vend proceeds", async () => {
  const { deps, calls } = makeDeps({ config: { paymentLinkId: null } });
  const res = await handleRequest(
    await signedPost(
      event("checkout.session.completed", session({ payment_link: null })),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 1, "vend proceeds");
  assert(
    calls.logs.some((l) => l.includes("pin unset")),
    "log-only warning",
  );
});

Deno.test("amount below floor -> vend proceeds + warning log", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event("checkout.session.completed", session({ amount_total: 1 })),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 1, "vend proceeds");
  assert(
    calls.logs.some((l) => l.includes("AMOUNT BELOW FLOOR")),
    "warning log",
  );
});

Deno.test("unknown event type -> 200, no claim", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(event("payment_intent.succeeded", session())),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("GET /health buckets: empty / low / ok, stuck false", async () => {
  for (const pool of ["empty", "low", "ok"] as const) {
    const { deps } = makeDeps({ pool });
    const res = await handleRequest(
      new Request("http://localhost/stripe-webhook/health"),
      deps,
    );
    assertEquals(res.status, 200, `status for ${pool}`);
    const body = await res.json();
    assertEquals(body.pool, pool, "bucket");
    assertEquals(body.ok, true, "ok flag");
    assertEquals(body.stuck, false, "stuck flag");
  }
});

Deno.test("GET /health surfaces stuck vends", async () => {
  const { deps } = makeDeps({ stuck: true });
  const res = await handleRequest(
    new Request("http://localhost/stripe-webhook/health"),
    deps,
  );
  assertEquals(res.status, 200, "status");
  const body = await res.json();
  assertEquals(body.stuck, true, "stuck flag raised");
});

Deno.test("GET /health with pool_depth failure -> 500 with ok:false", async () => {
  const { deps } = makeDeps({ pool: new Error("db down") });
  const res = await handleRequest(
    new Request("http://localhost/stripe-webhook/health"),
    deps,
  );
  assertEquals(res.status, 500, "status");
  const body = await res.json();
  assertEquals(body.ok, false, "ok flag false on failure");
});

Deno.test("GET /health with stuck_vends failure -> 500", async () => {
  const { deps } = makeDeps({ stuck: new Error("db down") });
  const res = await handleRequest(
    new Request("http://localhost/stripe-webhook/health"),
    deps,
  );
  assertEquals(res.status, 500, "status");
});

Deno.test("PUT on webhook root -> 405", async () => {
  const { deps } = makeDeps();
  const res = await handleRequest(
    new Request("http://localhost/stripe-webhook", { method: "PUT" }),
    deps,
  );
  assertEquals(res.status, 405, "status");
});

Deno.test("POST to /health -> 405; unknown path -> 404", async () => {
  const { deps } = makeDeps();
  const r1 = await handleRequest(
    new Request("http://localhost/stripe-webhook/health", { method: "POST" }),
    deps,
  );
  assertEquals(r1.status, 405, "POST health");
  const r2 = await handleRequest(
    new Request("http://localhost/stripe-webhook/nope"),
    deps,
  );
  assertEquals(r2.status, 404, "unknown path");
});

Deno.test("retry after send failure: cleared transient -> same key sent and marked", async () => {
  // First delivery: claim succeeds, SMTP fails -> 500 (covered elsewhere).
  // This is the follow-on Stripe retry: claim returns the SAME key (still
  // unmarked), send now succeeds, row gets marked.
  const { deps, calls } = makeDeps({
    vend: { key: "DROBU-already.claimed", payloadHex: "ab02", emailSentAt: null },
  });
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", session())),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.sends.length, 1, "sent on retry");
  assertEquals(calls.sends[0].key, "DROBU-already.claimed", "same key");
  assertEquals(calls.marks.length, 1, "marked on retry");
});

Deno.test("customer_details entirely null -> 200, no claim", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event(
        "checkout.session.completed",
        session({ customer_details: null }),
      ),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.claims.length, 0, "no claim");
});

Deno.test("malformed session shape (missing payment_status) -> 500, no claim", async () => {
  const { deps, calls } = makeDeps();
  const s = session() as unknown as Record<string, unknown>;
  delete s.payment_status;
  const res = await handleRequest(
    await signedPost(event("checkout.session.completed", s as never)),
    deps,
  );
  assertEquals(res.status, 500, "status");
  assertEquals(calls.claims.length, 0, "no claim");
  assert(
    calls.logs.some((l) => l.includes("MALFORMED SESSION SHAPE")),
    "loud drift breadcrumb",
  );
});

Deno.test("unpaid gate fires before the email gate (breadcrumb accuracy)", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    await signedPost(
      event(
        "checkout.session.completed",
        session({ payment_status: "unpaid", customer_details: null }),
      ),
    ),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assert(
    calls.logs.some((l) => l.includes("unpaid")),
    "deferring breadcrumb",
  );
  assert(
    !calls.logs.some((l) => l.includes("NO CUSTOMER EMAIL")),
    "no false vend-manually alarm for an unpaid session",
  );
});

Deno.test("buildLicenseEmail: key on its own line in text, inside <pre> in html", async () => {
  const { buildLicenseEmail } = await import("../stripe-webhook/email.ts");
  const key = "DROBU-somepayload.somesignature";
  const msg = buildLicenseEmail(key);
  assert(
    msg.text.split("\n").some((l) => l.trim() === key),
    "text part carries the key as an entire line",
  );
  assert(
    /<pre[^>]*>[^<]*DROBU-somepayload\.somesignature[^<]*<\/pre>/.test(msg.html),
    "html part carries the key inside <pre>",
  );
  assert(msg.subject.length > 0, "subject present");
});
