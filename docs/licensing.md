# Licensing

How Drobu's payment, trial, and activation flow fits together.

## The model

Drobu is a **$14.99 one-time purchase**. New users get a **14-day free trial** with full functionality — no payment method required up front. After day 14, the floating panel won't open until a valid license key is entered. Clipboard monitoring keeps running in the background during the gate so the user's history is preserved.

There is no subscription, no recurring billing, and no recurring license check. Customers buy once, get all 1.x updates, keep using Drobu indefinitely.

## How a license key works

Every license key is a cryptographic signature over a random payload, signed with Drobu's Ed25519 private key. The matching public key is baked into the app binary at `Info.plist:DrobuLicensePublicKey`.

When a customer pastes a key, Drobu verifies the signature **entirely offline** using `CryptoKit.Curve25519.Signing`. No server contact, no internet required, no phone-home. The key is then stored in the user's macOS Keychain (account `active-license`, service `com.danielius.ClipboardHistory.license`).

License key format:

```
DROBU-<base64url(32 random payload bytes)>.<base64url(64-byte Ed25519 signature)>
```

Example (truncated):

```
DROBU-uNt_pYTAUhuG7SftM2wPvWXR…ESM4.ZAiRm8iWz06ZjjC_mluvY-V1p…CtCw
```

The total key string is ~110 characters, paste-friendly, and survives email line-wrapping when copy-pasted as a single block.

## The keypair

The Ed25519 keypair is generated **once** by the developer (you), stored in the developer's macOS Keychain, and the public half is committed to the repo. The private half never leaves your Keychain. It never enters CI, never enters the repo, never enters a build artifact.

To regenerate from scratch:

```bash
./tools/generate-license-keypair.sh
```

This is destructive — running it invalidates every key you've ever issued, because the new public key won't verify signatures from the old private key. The script refuses to run if a keypair already exists in Keychain; pass `--force` to override (don't, unless you mean it).

After generation, the script prints the new base64-encoded public key. Paste it into `Sources/DrobuCore/Info.plist` under `DrobuLicensePublicKey` and commit. The next build embeds the new public key; subsequent builds will verify keys signed by the new private key.

## Issuing keys to customers

Fulfillment is **automated**: a Stripe payment triggers a webhook (a Supabase Edge Function) that vends one pre-signed key from a pool and emails it to the customer within about a minute. See [Automated fulfillment](#automated-fulfillment) below for the architecture; operational procedures live in the private support runbook.

The **manual fallback** remains for outages and support cases:

1. Find the customer's email (and checkout session id, `cs_...`) in the Stripe dashboard.
2. Run:
   ```bash
   ./tools/issue-license-key.sh customer@example.com --session cs_XXXX
   ```
   `--session` first checks whether that purchase already has a vended key (one payment must never yield two keys) and records the hand-issued key upstream so a later webhook retry returns the same key. Omit it only for non-Stripe issuance (gifts, replacements after key rotation).
3. The script reads your private key from Keychain, signs a fresh random payload, and prints the formatted license key.
4. Copy the key, email it to the customer with a "Welcome to Drobu" message.
5. The script appends a row to `tools/license-log.csv` (gitignored) for your audit trail.

The log columns are `timestamp,email,payload_hex` (pool batches log with `POOL` as the email until vended). Keep this CSV — it's one input of the reconciliation join, and your record of who has a valid key if you ever need to issue a refund, revoke a leaked key, or look up a customer's purchase later.

## Verification path inside the app

On every launch and during the panel-show flow, Drobu checks two things in order:

1. **Activated?** If a license key is in Keychain and its signature verifies against the embedded public key, the app is fully unlocked. The trial timer is ignored.
2. **Trial state?** If the first-launch timestamp (Keychain account `trial-start`) is within 14 days of now, the trial is active. Otherwise expired.

When the user invokes the global hotkey:

- **Trial active** or **Activated** → floating clipboard panel opens.
- **Trial expired** without a key → `ActivationPanel` opens instead. The user sees the Buy button (opens `drobu.app/buy` → Stripe) and a paste-key field. Activation closes the panel; next hotkey press opens the normal clipboard panel.

The clipboard monitor (background polling of `NSPasteboard`) runs regardless of license state. The user's data is preserved across the trial→expired transition and reappears as soon as they activate.

## Storage

| Item | Where | Why Keychain not UserDefaults |
|---|---|---|
| Trial-start timestamp | Keychain (`com.danielius.ClipboardHistory.license` / `trial-start`) | Survives `defaults delete` and most pref-reset attempts. |
| Last-seen clock anchor | Keychain (same service / `last-seen`) | Clamps trial math to the latest moment ever observed, so rolling the system clock back can't regain trial days. |
| Active license key | Keychain (`com.danielius.ClipboardHistory.license` / `active-license`) | Same protection. Note: Keychain does **not** sync these items across Macs (the store doesn't set `kSecAttrSynchronizable`) — and it doesn't need to: one key activates any number of the customer's Macs; paste it on each machine. |
| Ed25519 public key | App `Info.plist` | Baked into the binary at build time. Never changes during the life of a major version. Tampering with the binary breaks the code signature, which Sparkle refuses to update past. |
| Ed25519 private key (developer) | Developer's Keychain | Same threat model as your Sparkle signing key. Back up via Keychain Access → File → Export. |

## Threat model (summary)

Drobu's licensing favors paying-customer experience over DRM strength: verification is fully offline, there is no phone-home, and enforcement aims to keep honest users honest rather than stop determined crackers. The trial gate defends against casual non-payment, including trial extension via clock rollback (the persisted clock anchor clamps the trial math). One key deliberately activates any number of the customer's Macs. The detailed threat model — limits of the scheme, diagnostics, and reset procedures for legitimate support cases — lives in the private support runbook, not in this public repo.

## Payment-link contract

The bare Stripe Payment Link URL shipped inside binaries v1.2–v1.5.2 is a **permanent public contract**: never deactivate that link and never rotate it to a new one — installed apps' Buy buttons point at it forever, and Sparkle updates are optional. Price changes edit the existing link in place (see the price-change checklist in CLAUDE.md). Later binaries point at `https://drobu.app/buy`, a redirect under our control — that URL is the next permanent contract; never move it without a forward. Both URLs (and the `drobu.app` MX records) are watched by the daily `payment-links-monitor` workflow and the `release.sh` preflight.

## Automated fulfillment

A Stripe payment triggers `supabase/functions/stripe-webhook`, which vends a **pre-signed** key from a Postgres pool and emails it via SMTP. The deliberate design decision — replacing an earlier sketch that would have exported the private key to a cloud secret store — is that **the Ed25519 private key never leaves the developer's Keychain**: keys are minted offline in batches (`tools/mint-license-pool.sh`) and the cloud only ever stores finished, opaque key strings. A cloud compromise leaks a bounded batch of unclaimed keys, never the ability to forge.

The moving parts:

1. **Stripe webhook** (live mode) delivers `checkout.session.completed` / `checkout.session.async_payment_succeeded` / `checkout.session.async_payment_failed` to the Edge Function. Every request is authenticated by Stripe's HMAC signature; vending is gated on `payment_status` (delayed payment methods fulfill on the later success event).
2. **Atomic, idempotent vend**: one key per checkout session, enforced by a unique constraint + `FOR UPDATE SKIP LOCKED` claim in Postgres. Stripe retries (up to 72h) always receive the *same* key, and a retry after a transient email failure re-sends rather than re-vends.
3. **Email** goes out from the Drobu mailbox over SMTP, with the key on its own line / in a `<pre>` block (line-wrapped keys are the top historical activation failure).
4. **Monitoring**: the daily `payment-links-monitor` workflow checks the function's health route, the pool depth, and the Stripe endpoint's configuration (a disabled endpoint delivers nothing, silently); `release.sh`'s preflight mirrors the health check.
5. **Audit**: every claim records the session id, email, and `payload_hex`; `tools/export-license-claims.sh` exports them for the reconciliation join against Stripe's payment list and the local CSV.

Operational procedures (secrets, failure playbooks, reconciliation cadence, key-rotation interplay with the pool) live in the private support runbook — not in this public document.

## Operational runbook

**A customer paid but no key arrived** (webhook outage, bounced email): grab the checkout session id from the Stripe dashboard and run `./tools/issue-license-key.sh their-email@example.com --session cs_XXXX`, copy the output, email it. If the session already has a vended key, the script prints that key instead of minting a second one.

**A customer says their key doesn't work**: ask them to copy the entire key including the `DROBU-` prefix and paste it without trailing spaces. If activation still fails, the most likely cause is line-wrapping in their email — re-send the key with `<pre>` formatting or in a code block.

**A customer wants a refund**: the public policy is **all sales are final** — the 14-day full-functionality trial is the evaluation period (see `website/src/pages/terms.astro` and the FAQ). There is no advertised money-back guarantee, so this is now a discretionary, case-by-case decision (genuine breakage, duplicate charge, or an EU/UK statutory withdrawal request), not a routine one. If you do choose to refund: process the payment side in the Stripe dashboard (note that Stripe's fee is not returned), note the email in `tools/license-log.csv`, and revoke the key so it can't keep activating — the revocation posture is documented in the private support runbook.

**I lost my private key**: the Sparkle pattern applies — back up via Keychain Access → File → Export *before* you have a crisis. If lost without backup, you'll need to generate a new keypair (see [The keypair](#the-keypair)), ship a new Drobu version with the new public key, re-issue keys to every existing customer. Painful but tractable.

**A keypair was leaked**: same recovery as "lost private key" — rotate. Then update `revoked-keys.txt` to mark every key signed by the old private key as revoked.
