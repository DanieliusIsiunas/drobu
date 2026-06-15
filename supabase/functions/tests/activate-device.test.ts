// deno test suite for the activate-device handler.
//
// Run from the repo root:
//   deno test --allow-env --allow-net=none \
//     --config supabase/functions/activate-device/deno.json \
//     supabase/functions/tests/activate-device.test.ts
//
// Signature verification runs through the REAL verifyLicenseKey + Web Crypto
// Ed25519 path (against a test keypair generated here), proving the exact
// verification index.ts uses — not a mock of it. Everything past verification
// (the cap decision) runs through injected deps per handler.ts's seam; the cap
// math itself lives in SQL (U1) and is verified live at rollout.

import {
  type ActivatedDevice,
  handleRequest,
  type HandlerDeps,
  type Verdict,
} from "../activate-device/handler.ts";
import { verifyLicenseKey } from "../activate-device/verify.ts";

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}
function assertEquals<T>(actual: T, expected: T, msg?: string) {
  if (actual !== expected) {
    throw new Error(`${msg ?? "assertEquals"}: expected ${expected}, got ${actual}`);
  }
}

// --- Test keypair + key construction (real Ed25519) ------------------------

const keyPair = await crypto.subtle.generateKey(
  { name: "Ed25519" },
  true,
  ["sign", "verify"],
) as CryptoKeyPair;
const PUB_RAW = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));

// A second, unrelated keypair to forge a structurally-valid but bad-signature key.
const otherPair = await crypto.subtle.generateKey(
  { name: "Ed25519" },
  true,
  ["sign", "verify"],
) as CryptoKeyPair;

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function makeKey(priv: CryptoKey, payload?: Uint8Array<ArrayBuffer>): Promise<string> {
  const p = payload ?? crypto.getRandomValues(new Uint8Array(32));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, priv, p));
  return `DROBU-${b64url(p)}.${b64url(sig)}`;
}

// --- Injected-deps harness -------------------------------------------------

interface Calls {
  activations: Array<{ payloadHex: string; deviceHash: string; deviceName: string | null }>;
  deactivations: Array<{ payloadHex: string; deviceHash: string }>;
  logs: string[];
}

function makeDeps(opts: {
  verdict?: Verdict | Error;
  deactivateError?: Error;
} = {}): { deps: HandlerDeps; calls: Calls } {
  const calls: Calls = { activations: [], deactivations: [], logs: [] };
  const deps: HandlerDeps = {
    async verifyKey(key) {
      const payloadHex = await verifyLicenseKey(key, PUB_RAW);
      return { payloadHex };
    },
    // deno-lint-ignore require-await
    async activateDevice(payloadHex, deviceHash, deviceName) {
      calls.activations.push({ payloadHex, deviceHash, deviceName });
      const v = opts.verdict ?? { status: "activated", activeDevices: [], email: null };
      if (v instanceof Error) throw v;
      return v;
    },
    // deno-lint-ignore require-await
    async deactivateDevice(payloadHex, deviceHash) {
      if (opts.deactivateError) throw opts.deactivateError;
      calls.deactivations.push({ payloadHex, deviceHash });
    },
    log: (l) => calls.logs.push(l),
  };
  return { deps, calls };
}

function activatePost(body: Record<string, unknown>, path = "/activate-device"): Request {
  return new Request(`http://localhost${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const devices = (n: number): ActivatedDevice[] =>
  Array.from({ length: n }, (_, i) => ({
    device_name: `Mac ${i + 1}`,
    activated_at: "2026-06-15T10:00:00Z",
  }));

// --- Tests -----------------------------------------------------------------

Deno.test("valid key under cap -> 200 activated, RPC called with payload_hex", async () => {
  const { deps, calls } = makeDeps();
  const key = await makeKey(keyPair.privateKey);
  const res = await handleRequest(
    activatePost({ key, deviceHash: "devhash1", deviceName: "Daniel's MacBook" }),
    deps,
  );
  assertEquals(res.status, 200, "status");
  const json = await res.json();
  assertEquals(json.status, "activated", "verdict");
  assertEquals(calls.activations.length, 1, "one activation");
  assertEquals(calls.activations[0].deviceHash, "devhash1", "device hash forwarded");
  assertEquals(calls.activations[0].deviceName, "Daniel's MacBook", "device name forwarded");
  assert(calls.activations[0].payloadHex.length === 64, "payload_hex is 32-byte hex");
  assert(!calls.logs.some((l) => l.includes("DROBU-")), "no key material in logs");
});

Deno.test("at cap, new device -> 200 over_cap with device list", async () => {
  const { deps } = makeDeps({
    verdict: { status: "over_cap", activeDevices: devices(3), email: "a@b.com" },
  });
  const key = await makeKey(keyPair.privateKey);
  const res = await handleRequest(
    activatePost({ key, deviceHash: "devhash4", deviceName: "Mac 4" }),
    deps,
  );
  assertEquals(res.status, 200, "status");
  const json = await res.json();
  assertEquals(json.status, "over_cap", "verdict");
  assertEquals(json.activeDevices.length, 3, "three active devices returned");
  assertEquals(json.email, "a@b.com", "email passed through");
});

Deno.test("refunded license -> 200 revoked", async () => {
  const { deps } = makeDeps({
    verdict: { status: "revoked", activeDevices: [], email: "a@b.com" },
  });
  const key = await makeKey(keyPair.privateKey);
  const res = await handleRequest(
    activatePost({ key, deviceHash: "devhash1" }),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals((await res.json()).status, "revoked", "verdict");
});

Deno.test("email present for vended key, null for manual key", async () => {
  const withEmail = makeDeps({
    verdict: { status: "activated", activeDevices: devices(1), email: "buyer@x.com" },
  });
  const r1 = await handleRequest(
    activatePost({ key: await makeKey(keyPair.privateKey), deviceHash: "d1" }),
    withEmail.deps,
  );
  assertEquals((await r1.json()).email, "buyer@x.com", "vended key email");

  const noEmail = makeDeps(); // default verdict has email: null
  const r2 = await handleRequest(
    activatePost({ key: await makeKey(keyPair.privateKey), deviceHash: "d1" }),
    noEmail.deps,
  );
  assertEquals((await r2.json()).email, null, "manual key email null");
});

Deno.test("malformed key (no DROBU- prefix) -> 400, activate never called", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    activatePost({ key: "not-a-key", deviceHash: "d1" }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.activations.length, 0, "no activation");
});

Deno.test("valid shape but signed by a different key -> 400 (bad signature)", async () => {
  const { deps, calls } = makeDeps();
  const forged = await makeKey(otherPair.privateKey); // verifies against PUB_RAW => fails
  const res = await handleRequest(
    activatePost({ key: forged, deviceHash: "d1" }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.activations.length, 0, "no activation — anti-griefing");
});

Deno.test("wrong-length signature -> 400", async () => {
  const { deps, calls } = makeDeps();
  const payload = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const shortSig = b64url(new Uint8Array(10));
  const res = await handleRequest(
    activatePost({ key: `DROBU-${payload}.${shortSig}`, deviceHash: "d1" }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.activations.length, 0, "no activation");
});

Deno.test("missing deviceHash -> 400 before verification", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    activatePost({ key: await makeKey(keyPair.privateKey) }),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.activations.length, 0, "no activation");
});

Deno.test("invalid json body -> 400", async () => {
  const { deps } = makeDeps();
  const res = await handleRequest(
    new Request("http://localhost/activate-device", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not json",
    }),
    deps,
  );
  assertEquals(res.status, 400, "status");
});

Deno.test("activateDevice throws (DB down) -> 500 (retryable)", async () => {
  const { deps } = makeDeps({ verdict: new Error("activate_device: db down") });
  const res = await handleRequest(
    activatePost({ key: await makeKey(keyPair.privateKey), deviceHash: "d1" }),
    deps,
  );
  assertEquals(res.status, 500, "status");
});

Deno.test("deactivate route with valid key -> 200, deactivateDevice called", async () => {
  const { deps, calls } = makeDeps();
  const key = await makeKey(keyPair.privateKey);
  const res = await handleRequest(
    activatePost({ key, deviceHash: "devhash1" }, "/activate-device/deactivate"),
    deps,
  );
  assertEquals(res.status, 200, "status");
  assertEquals(calls.deactivations.length, 1, "one deactivation");
  assertEquals(calls.deactivations[0].deviceHash, "devhash1", "device hash forwarded");
  assertEquals(calls.activations.length, 0, "no activation on deactivate route");
});

Deno.test("deactivate route with bad signature -> 400", async () => {
  const { deps, calls } = makeDeps();
  const res = await handleRequest(
    activatePost(
      { key: await makeKey(otherPair.privateKey), deviceHash: "d1" },
      "/activate-device/deactivate",
    ),
    deps,
  );
  assertEquals(res.status, 400, "status");
  assertEquals(calls.deactivations.length, 0, "no deactivation");
});

Deno.test("deactivateDevice throws -> 500", async () => {
  const { deps } = makeDeps({ deactivateError: new Error("db down") });
  const res = await handleRequest(
    activatePost(
      { key: await makeKey(keyPair.privateKey), deviceHash: "d1" },
      "/activate-device/deactivate",
    ),
    deps,
  );
  assertEquals(res.status, 500, "status");
});

Deno.test("GET /health -> 200; unknown path -> 404; PUT -> 405", async () => {
  const { deps } = makeDeps();
  const h = await handleRequest(
    new Request("http://localhost/activate-device/health"),
    deps,
  );
  assertEquals(h.status, 200, "health");
  const nf = await handleRequest(
    new Request("http://localhost/activate-device/nope", { method: "POST" }),
    deps,
  );
  assertEquals(nf.status, 404, "unknown path");
  const put = await handleRequest(
    new Request("http://localhost/activate-device", { method: "PUT" }),
    deps,
  );
  assertEquals(put.status, 405, "method not allowed");
});

Deno.test("payload_hex derivation matches lowercase hex of the payload", async () => {
  // A fixed payload -> known lowercase hex (must match the mint tools'
  // String(format: "%02x") so the activations<->license_keys join works).
  const payload = new Uint8Array(32);
  payload[0] = 0xab;
  payload[31] = 0x0f;
  const key = await makeKey(keyPair.privateKey, payload);
  const hex = await verifyLicenseKey(key, PUB_RAW);
  assertEquals(hex.slice(0, 2), "ab", "first byte lowercase hex");
  assertEquals(hex.slice(-2), "0f", "last byte lowercase hex, zero-padded");
  assertEquals(hex.length, 64, "32 bytes -> 64 hex chars");
});
