// Pure request handler for the device-activation endpoint.
//
// Layers an ONLINE device cap on the OFFLINE license: the client sends a
// signature-valid key + a device fingerprint; this function verifies the
// signature (anti-griefing — a leaked payload_hex alone can't burn a stranger's
// seats), derives the license identity, and asks Postgres to enforce the cap.
//
// Every effect is injected via HandlerDeps so `deno test` exercises the full
// routing + verify + verdict flow with constructed Requests. index.ts is the
// only file that touches the real public key / Supabase.
//
// Response-code contract (per .claude/rules/stripe-webhook-supabase.md):
//   malformed body / bad signature ........... 400  (caller error, not retried)
//   clean verdict (activated/over_cap/revoked) 200  (the verdict is in the BODY,
//                                                    NOT the status line — an
//                                                    over-cap is a SUCCESSFUL
//                                                    evaluation, never a 5xx)
//   DB / RPC / infra failure ................. 500  (retryable)
//   GET <fn>/health .......................... 200 liveness
//   anything else ............................ 404/405
//
// Responses carry the buyer email (for the app's "Licensed to {email}") but
// NEVER the license key (the app already holds it).

export interface ActivatedDevice {
  device_name: string | null;
  activated_at: string;
}

export type ActivationStatus = "activated" | "over_cap" | "revoked";

export interface Verdict {
  status: ActivationStatus;
  activeDevices: ActivatedDevice[];
  email: string | null;
}

export interface HandlerDeps {
  // Returns the license identity (payload_hex); throws on malformed/bad-sig.
  verifyKey(key: string): Promise<{ payloadHex: string }>;
  activateDevice(
    payloadHex: string,
    deviceHash: string,
    deviceName: string | null,
  ): Promise<Verdict>;
  deactivateDevice(payloadHex: string, deviceHash: string): Promise<void>;
  log(line: string): void;
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Paths look like /activate-device, /activate-device/deactivate,
// /activate-device/health. IMPORTANT: the prefix literal must equal the
// function directory name — renaming the dir requires updating this string
// (and the app's endpoint URL) in the same change.
function route(
  pathname: string,
): "activate" | "deactivate" | "health" | "unknown" {
  const p = pathname.replace(/^\/activate-device/, "").replace(/\/+$/, "");
  if (p === "" || p === "/") return "activate";
  if (p === "/deactivate") return "deactivate";
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
    return json(200, { ok: true });
  }
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  let body: { key?: unknown; deviceHash?: unknown; deviceName?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid json" });
  }
  const key = typeof body?.key === "string" ? body.key : null;
  const deviceHash = typeof body?.deviceHash === "string" ? body.deviceHash : null;
  const rawDeviceName = typeof body?.deviceName === "string" ? body.deviceName : null;
  if (!key || !deviceHash) {
    return json(400, { error: "key and deviceHash are required" });
  }
  // The client always sends SHA256 lowercase hex (64 chars). Reject anything
  // else: it's garbage or abuse, and a strict shape stops a key holder from
  // spraying arbitrary distinct hashes to bloat the soft-deleted history.
  if (!/^[0-9a-f]{64}$/.test(deviceHash)) {
    return json(400, { error: "deviceHash must be a 64-character hex string" });
  }
  // Clamp the human-readable name (attacker-controlled free text on a public
  // endpoint) before it reaches the DB / the activated-device list.
  const deviceName = rawDeviceName ? rawDeviceName.slice(0, 200) : null;

  let payloadHex: string;
  try {
    ({ payloadHex } = await deps.verifyKey(key));
  } catch (e) {
    // Malformed or bad signature — caller error, not retryable. No key material
    // in the log (the message names the failure mode, not the bytes).
    deps.log(
      `ActivateDevice: key rejected: ${e instanceof Error ? e.message : e}`,
    );
    return json(400, { error: "invalid license key" });
  }

  if (r === "deactivate") {
    try {
      await deps.deactivateDevice(payloadHex, deviceHash);
    } catch (e) {
      deps.log(`ActivateDevice: deactivate failed: ${e} (payload_hex=${payloadHex})`);
      return json(500, { error: "deactivate failed" });
    }
    deps.log(`ActivateDevice: deactivated device on payload_hex=${payloadHex}`);
    return json(200, { ok: true });
  }

  let verdict: Verdict;
  try {
    verdict = await deps.activateDevice(payloadHex, deviceHash, deviceName);
  } catch (e) {
    // DB/RPC failure is retryable — the client treats a non-200 as "unreachable"
    // and fails open within the grace window.
    deps.log(`ActivateDevice: activate failed: ${e} (payload_hex=${payloadHex})`);
    return json(500, { error: "activation failed" });
  }

  deps.log(
    `ActivateDevice: ${verdict.status} payload_hex=${payloadHex} (${verdict.activeDevices.length} active)`,
  );
  return json(200, {
    status: verdict.status,
    activeDevices: verdict.activeDevices,
    email: verdict.email,
  });
}
