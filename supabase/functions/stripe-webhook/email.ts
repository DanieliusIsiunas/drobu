// SMTP transport seam + license-email builder.
//
// Hostinger SMTP, port 465 implicit TLS only — Supabase Edge Functions block
// outbound 25 and 587, so there is no STARTTLS fallback. If this transport
// ever proves unreliable, the seam is the swap point for an HTTP provider
// (Resend): createSender is the only export index.ts wires in.
//
// The key goes out on its OWN LINE in text/plain and inside <pre> in HTML —
// line-wrapped keys are the #1 historical activation-failure cause.

import nodemailer from "nodemailer";

export interface MailConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  from: string;
  replyTo: string;
}

const DOWNLOAD_URL = "https://drobu.app";

export function buildLicenseEmail(key: string): {
  subject: string;
  text: string;
  html: string;
} {
  const subject = "Your Drobu license key";
  const text = [
    "Thanks for buying Drobu!",
    "",
    "Your license key (copy the whole line, including the DROBU- prefix):",
    "",
    key,
    "",
    "To activate:",
    "1. Open Drobu (download: " + DOWNLOAD_URL + ")",
    "2. Press the Drobu hotkey, or open Settings -> License",
    "3. Paste the key and press Activate",
    "",
    "The same key activates Drobu on all your Macs.",
    "",
    "Questions or trouble activating? Just reply to this email.",
  ].join("\n");

  const html = `<!doctype html>
<html><body style="font-family: -apple-system, Helvetica, Arial, sans-serif; line-height: 1.5; color: #1a1a1a;">
<p>Thanks for buying Drobu!</p>
<p>Your license key (copy the whole block, including the <code>DROBU-</code> prefix):</p>
<pre style="background:#f4f4f5;padding:12px;border-radius:6px;overflow-x:auto;white-space:pre;font-size:13px;">${key}</pre>
<p>To activate:</p>
<ol>
<li>Open Drobu (<a href="${DOWNLOAD_URL}">download</a>)</li>
<li>Press the Drobu hotkey, or open Settings &rarr; License</li>
<li>Paste the key and press Activate</li>
</ol>
<p>The same key activates Drobu on all your Macs.</p>
<p>Questions or trouble activating? Just reply to this email.</p>
</body></html>`;

  return { subject, text, html };
}

export function createSender(
  cfg: MailConfig,
): (to: string, key: string) => Promise<void> {
  const transporter = nodemailer.createTransport({
    host: cfg.host,
    port: cfg.port,
    secure: true, // implicit TLS — required shape for 465
    auth: { user: cfg.username, pass: cfg.password },
    // Keep the whole handler well inside Stripe's delivery window (and the
    // 10s success_url redirect hold): fail fast, let the 500 -> retry path
    // (with the idempotent claim) be the retry mechanism.
    connectionTimeout: 5_000,
    greetingTimeout: 5_000,
    socketTimeout: 10_000,
  });

  return async (to: string, key: string) => {
    const msg = buildLicenseEmail(key);
    // nodemailer's socketTimeout is per SMTP command, not per send — a slow
    // server can stack commands past Stripe's delivery window. The hard
    // deadline bounds the whole send; on timeout the handler 500s and the
    // idempotent retry chain re-attempts (same key, no double-vend).
    await withDeadline(
      transporter.sendMail({
        from: cfg.from,
        to,
        replyTo: cfg.replyTo,
        subject: msg.subject,
        text: msg.text,
        html: msg.html,
      }),
      15_000,
      "SMTP send exceeded 15s deadline",
    );
  };
}

function withDeadline<T>(p: Promise<T>, ms: number, msg: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(msg)), ms);
    p.then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e) => {
        clearTimeout(t);
        reject(e);
      },
    );
  });
}
