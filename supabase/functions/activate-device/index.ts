// Entry point: wires the real Ed25519 public key + the Postgres activation RPCs
// into the pure handler. All logic lives in handler.ts (deno tested); this file
// is deliberately thin (mirrors stripe-webhook/index.ts).

import { createClient } from "@supabase/supabase-js";
import { handleRequest, type HandlerDeps, type Verdict } from "./handler.ts";
import { decodePublicKey, verifyLicenseKey } from "./verify.ts";

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing required env: ${name}`);
  return v;
}

// The PUBLIC license key (same base64 as Info.plist DrobuLicensePublicKey).
// Custody preserved — the private key never reaches the backend. Boot fails
// loudly if it's missing/malformed rather than 500-ing every activation.
const LICENSE_PUBLIC_KEY = decodePublicKey(requireEnv("DROBU_LICENSE_PUBLIC_KEY"));

// The device cap, passed to the SQL as p_cap. If you change this number, also
// update the user-facing copy that states "3 Macs": SettingsView.swift (the
// "up to 3 Macs" disclosure) and website/src/pages/terms.astro.
const DEVICE_CAP = 3;

const supabase = createClient(
  requireEnv("SUPABASE_URL"),
  requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
);

// supabase-js resolves { data, error } instead of throwing — each wrapper
// translates `error` into a throw so the handler's 500 path engages.
const deps: HandlerDeps = {
  async verifyKey(key) {
    const payloadHex = await verifyLicenseKey(key, LICENSE_PUBLIC_KEY);
    return { payloadHex };
  },

  async activateDevice(payloadHex, deviceHash, deviceName): Promise<Verdict> {
    const { data, error } = await supabase.rpc("activate_device", {
      p_payload_hex: payloadHex,
      p_device_hash: deviceHash,
      p_device_name: deviceName,
      p_cap: DEVICE_CAP,
    });
    if (error) throw new Error(`activate_device: ${error.message}`);
    const row = Array.isArray(data) ? data[0] : data;
    if (!row?.status) throw new Error("activate_device returned no row");
    return {
      status: row.status,
      activeDevices: row.active_devices ?? [],
      email: row.email ?? null,
    };
  },

  async deactivateDevice(payloadHex, deviceHash) {
    const { error } = await supabase.rpc("deactivate_device", {
      p_payload_hex: payloadHex,
      p_device_hash: deviceHash,
    });
    if (error) throw new Error(`deactivate_device: ${error.message}`);
  },

  log: (line) => console.log(line),
};

Deno.serve((req) => handleRequest(req, deps));
