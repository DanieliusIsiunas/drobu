// License-key parsing + Ed25519 signature verification, shared by index.ts
// (real public key from env) and the deno tests (a test keypair). This is the
// SERVER half of the offline verification that LicenseManager.verifyKey does
// on the client — same format, same checks — so a device can only be activated
// against a signature-valid key. Custody preserved: only the PUBLIC key is here
// (it already ships in every binary's Info.plist); the private key never
// leaves the dev Keychain.
//
// Key format (matches issue-license-key.sh / mint-license-pool.sh):
//   DROBU-<base64url(32-byte payload)>.<base64url(64-byte signature)>
// payload_hex (the license identity that joins to license_keys) is the
// LOWERCASE hex of the payload — must match `String(format: "%02x", $0)` from
// the mint tools, or the activations<->license_keys join silently misses.

export class MalformedKeyError extends Error {}
export class BadSignatureError extends Error {}

const KEY_PREFIX = "DROBU-";

// Returns an ArrayBuffer-backed view explicitly — Web Crypto's BufferSource
// rejects the generic `Uint8Array<ArrayBufferLike>` default (it admits
// SharedArrayBuffer), so the crypto-facing types below are all pinned.
function base64Decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// URL-safe base64 dialect used by the mint tools: `+`→`-`, `/`→`_`, no `=`.
function base64UrlDecode(s: string): Uint8Array<ArrayBuffer> {
  let n = s.replaceAll("-", "+").replaceAll("_", "/");
  while (n.length % 4 !== 0) n += "=";
  return base64Decode(n);
}

function toHexLower(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Decode + length-check the base64 (standard, not URL) public key from env. */
export function decodePublicKey(b64: string): Uint8Array<ArrayBuffer> {
  const bytes = base64Decode(b64.trim());
  if (bytes.length !== 32) {
    throw new Error(`DROBU_LICENSE_PUBLIC_KEY must decode to 32 bytes, got ${bytes.length}`);
  }
  return bytes;
}

export interface ParsedKey {
  payload: Uint8Array<ArrayBuffer>;
  signature: Uint8Array<ArrayBuffer>;
  payloadHex: string;
}

/** Structural parse only — throws MalformedKeyError, never verifies the sig. */
export function parseKey(key: string): ParsedKey {
  if (!key.startsWith(KEY_PREFIX)) {
    throw new MalformedKeyError("missing DROBU- prefix");
  }
  const body = key.slice(KEY_PREFIX.length);
  const dot = body.indexOf(".");
  if (dot < 0) throw new MalformedKeyError("missing '.' separator");
  let payload: Uint8Array<ArrayBuffer>;
  let signature: Uint8Array<ArrayBuffer>;
  try {
    payload = base64UrlDecode(body.slice(0, dot));
    signature = base64UrlDecode(body.slice(dot + 1));
  } catch {
    throw new MalformedKeyError("payload/signature not base64url");
  }
  // Ed25519 signatures are exactly 64 bytes; the issuer always uses 32-byte
  // payloads (matches the client's LicenseManager.verifyKey + the mint tools).
  // Pinning payload to exactly 32 keeps the server's accepted key shape from
  // ever diverging from the minted shape, so payload_hex can't take a
  // non-standard length and silently miss the license_keys join.
  if (signature.length !== 64 || payload.length !== 32) {
    throw new MalformedKeyError("unexpected payload/signature length");
  }
  return { payload, signature, payloadHex: toHexLower(payload) };
}

/** Parse + verify against the given raw public key. Returns the payload_hex
 *  (license identity) on success; throws MalformedKeyError / BadSignatureError. */
export async function verifyLicenseKey(
  key: string,
  publicKeyBytes: Uint8Array<ArrayBuffer>,
): Promise<string> {
  const { payload, signature, payloadHex } = parseKey(key);
  const pub = await crypto.subtle.importKey(
    "raw",
    publicKeyBytes,
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify({ name: "Ed25519" }, pub, signature, payload);
  if (!ok) throw new BadSignatureError("signature did not verify");
  return payloadHex;
}
