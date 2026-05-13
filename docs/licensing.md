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

## Issuing keys to customers (manual flow)

Today's flow is manual — fine for the first 5-20 customers, then we'll automate via a Stripe webhook (see [Future automation](#future-automation) below).

For each customer who pays:

1. Stripe emails you the standard `payment_intent.succeeded` notification with the customer's email.
2. Run:
   ```bash
   ./tools/issue-license-key.sh customer@example.com
   ```
3. The script reads your private key from Keychain, signs a fresh random payload, and prints the formatted license key.
4. Copy the key, email it to the customer with a "Welcome to Drobu" message.
5. The script appends a row to `tools/license-log.csv` (gitignored) for your audit trail.

The log columns are `timestamp,email,payload_hex`. Keep this CSV — it's your record of who has a valid key if you ever need to issue a refund, revoke a leaked key, or look up a customer's purchase later.

## Verification path inside the app

On every launch and during the panel-show flow, Drobu checks two things in order:

1. **Activated?** If a license key is in Keychain and its signature verifies against the embedded public key, the app is fully unlocked. The trial timer is ignored.
2. **Trial state?** If the first-launch timestamp (Keychain account `trial-start`) is within 14 days of now, the trial is active. Otherwise expired.

When the user invokes the global hotkey:

- **Trial active** or **Activated** → floating clipboard panel opens.
- **Trial expired** without a key → `ActivationPanel` opens instead. The user sees the Buy button (deep-links to Stripe) and a paste-key field. Activation closes the panel; next hotkey press opens the normal clipboard panel.

The clipboard monitor (background polling of `NSPasteboard`) runs regardless of license state. The user's data is preserved across the trial→expired transition and reappears as soon as they activate.

## Storage

| Item | Where | Why Keychain not UserDefaults |
|---|---|---|
| Trial-start timestamp | Keychain (`com.danielius.ClipboardHistory.license` / `trial-start`) | Survives `defaults delete` and most pref-reset attempts. Determined users with Keychain Access can still wipe it, but the bar is meaningfully higher. |
| Active license key | Keychain (`com.danielius.ClipboardHistory.license` / `active-license`) | Same protection. Also: storing it in Keychain makes it easy to share across Macs (Keychain sync) for the same user. |
| Ed25519 public key | App `Info.plist` | Baked into the binary at build time. Never changes during the life of a major version. Tampering with the binary breaks the code signature, which Sparkle refuses to update past. |
| Ed25519 private key (developer) | Developer's Keychain | Same threat model as your Sparkle signing key. Back up via Keychain Access → File → Export. |

## Threat model: what this defends against, what it doesn't

**It defends against:**

- Casual non-payers who download the binary directly and try to use it past 14 days — they're hard-gated.
- Users who try to extend the trial by `defaults delete`-ing — the timestamp is in Keychain.
- Tampered binaries with the verification call patched out — they fail Sparkle's signature check on update, so they get stuck on the version they cracked while paying users get new features and bug fixes.
- Replay attacks — every key is unique random bytes.

**It does NOT defend against:**

- A determined cracker who reverse-engineers Drobu, patches the `isValidSignature` call to always return true, and redistributes. This is true for **every** licensing system at the indie scale; it's not worth solving until you have evidence of actual sharing. The right next step then is per-device online activation, not making the offline check stronger.
- Customers sharing their key with a friend — the same key works on any number of machines. If this becomes a real problem, the upgrade path is per-device activation (online check), tracked in `Out of scope` below.
- Side-loading source compilation — anyone with Xcode can build Drobu from source. The friction (signing setup, Sparkle key, etc.) keeps this <1%.

## Future automation

The manual issuance flow is the floor; the ceiling is a Stripe webhook that auto-emails keys. Roughly:

1. **Cloudflare Worker** (~50 lines TS) deployed at `webhook.drobu.app/stripe`.
2. **Webhook listens for `checkout.session.completed`** from Stripe.
3. **Worker generates a license key** using a private key stored in Cloudflare's secrets store (the same Ed25519 private key, exported once).
4. **Worker emails the key** to the customer via Resend / Postmark / similar.
5. **Worker logs the issuance** in a Cloudflare D1 row or KV entry for audit.

Total ongoing cost: ~$0/month at low volume (Cloudflare free tier + email free tier). Setup: ~1 day. This lands in a separate plan when you're ready to stop emailing keys by hand.

## Operational runbook

**A customer paid but I haven't sent them a key**: run `./tools/issue-license-key.sh their-email@example.com`, copy the output, email it.

**A customer says their key doesn't work**: ask them to copy the entire key including the `DROBU-` prefix and paste it without trailing spaces. If activation still fails, the most likely cause is line-wrapping in their email — re-send the key with `<pre>` formatting or in a code block.

**A customer wants a refund / I want to revoke a key**: Drobu doesn't ship revocation today; the customer's key keeps working. Note their email in `tools/license-log.csv` and add the payload hex to a future `revoked-keys.txt` shipped via Sparkle. Implementation of the revocation check itself is out of scope for v1.

**I lost my private key**: the Sparkle pattern applies — back up via Keychain Access → File → Export *before* you have a crisis. If lost without backup, you'll need to generate a new keypair (see [The keypair](#the-keypair)), ship a new Drobu version with the new public key, re-issue keys to every existing customer. Painful but tractable.

**A keypair was leaked**: same recovery as "lost private key" — rotate. Then update `revoked-keys.txt` to mark every key signed by the old private key as revoked.
