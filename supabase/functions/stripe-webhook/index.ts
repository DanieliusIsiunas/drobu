// Entry point: wires real Stripe verification, the Postgres claim RPCs, and
// the SMTP sender into the pure handler. All logic lives in handler.ts (deno
// tested); this file is deliberately thin.

import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";
import {
  type EventLike,
  handleRequest,
  type HandlerDeps,
  type VendResult,
} from "./handler.ts";
import { createSender } from "./email.ts";

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing required env: ${name}`);
  return v;
}

// Webhook-only client: no Stripe API calls are made, so no real API key is
// needed — constructEventAsync only uses the signing secret.
const stripe = new Stripe(Deno.env.get("STRIPE_API_KEY") ?? "sk_unused");
const cryptoProvider = Stripe.createSubtleCryptoProvider();
const webhookSecret = requireEnv("STRIPE_WEBHOOK_SECRET");

const supabase = createClient(
  requireEnv("SUPABASE_URL"),
  requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
);

// supabase-js resolves { data, error } instead of throwing — every wrapper
// below translates `error` into a throw so the handler's 500 path engages.
const deps: HandlerDeps = {
  async verifyEvent(rawBody, signature) {
    if (!signature) throw new Error("missing stripe-signature header");
    const event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      webhookSecret,
      undefined,
      cryptoProvider,
    );
    return event as unknown as EventLike;
  },

  async claimKey(sessionId, email, amount, currency): Promise<VendResult> {
    const { data, error } = await supabase.rpc("claim_license_key", {
      p_session_id: sessionId,
      p_email: email,
      p_amount: amount,
      p_currency: currency,
    });
    if (error) throw new Error(`claim_license_key: ${error.message}`);
    const row = Array.isArray(data) ? data[0] : data;
    if (!row?.key) throw new Error("claim_license_key returned no row");
    return {
      key: row.key,
      payloadHex: row.payload_hex,
      emailSentAt: row.email_sent_at ?? null,
    };
  },

  async markEmailSent(sessionId) {
    const { error } = await supabase.rpc("mark_email_sent", {
      p_session_id: sessionId,
    });
    if (error) throw new Error(`mark_email_sent: ${error.message}`);
  },

  sendMail: createSender({
    host: Deno.env.get("SMTP_HOST") ?? "smtp.hostinger.com",
    port: Number(Deno.env.get("SMTP_PORT") ?? "465"),
    username: requireEnv("SMTP_USERNAME"),
    password: requireEnv("SMTP_PASSWORD"),
    from: Deno.env.get("MAIL_FROM") ?? "Drobu <license@drobu.app>",
    replyTo: Deno.env.get("MAIL_REPLY_TO") ?? "support@drobu.app",
  }),

  async poolDepth() {
    const { data, error } = await supabase.rpc("pool_depth");
    if (error) throw new Error(`pool_depth: ${error.message}`);
    if (data !== "ok" && data !== "low" && data !== "empty") {
      throw new Error(`pool_depth returned unexpected value: ${data}`);
    }
    return data;
  },

  config: {
    expectedLivemode: (Deno.env.get("EXPECTED_LIVEMODE") ?? "true") === "true",
    paymentLinkId: Deno.env.get("PAYMENT_LINK_ID") || null,
    amountFloor: Deno.env.get("AMOUNT_FLOOR")
      ? Number(Deno.env.get("AMOUNT_FLOOR"))
      : null,
  },

  log: (line) => console.log(line),
};

Deno.serve((req) => handleRequest(req, deps));
