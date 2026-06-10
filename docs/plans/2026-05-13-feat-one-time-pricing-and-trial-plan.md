---
title: Switch Drobu to one-time pricing with a 14-day in-app trial
date: 2026-05-13
status: active
---

# Switch Drobu to one-time pricing with a 14-day in-app trial

## Context

Drobu currently advertises a $9.99/mo subscription with a Stripe-managed 14-day free trial. The actual in-app code has zero licensing logic — anyone with the downloaded DMG has lifetime use, regardless of payment.

The user has reconsidered the commercial model and decided one-time pricing is a better fit for Drobu's utility-app category (matches Maccy, Bartender, CleanShot X, iStat Menus, Soulver). The new model:

- **Price**: $14.99 one-time (matches Maccy exactly; well below CleanShot X / Bartender)
- **Trial**: 14 days, handled in-app (Stripe is no longer involved in trial management)
- **Gate**: hard — when the trial expires and no license key is entered, the floating panel refuses to open. Clipboard monitoring keeps running in the background so the user's data is preserved; they just can't access it without activating
- **Licensing**: cryptographic offline keys (Ed25519). No backend required for the license check
- **Key issuance**: manual for the first customers (a shell script generates keys you email by hand). Stripe webhook automation is **out of scope** for this plan and lands in a follow-up

The existing Stripe Payment Link URL is unchanged in this plan — the user reconfigured the same slug to one-time pricing on Stripe's side.

The intended outcome: a complete, defensible payment-to-activation funnel that you can run end-to-end on a real card today, ship to the first 5-10 customers next week without code changes, and graduate to webhook-automated key delivery later.

## Approach

Three workstreams, executable in order:

1. **Marketing surface** — flip every "subscription" / "14-day free trial" / "$9.99/mo" reference to "$14.99 one-time" / "14-day free trial" (the trial phrasing stays, the model behind it changes). Pure copy work.
2. **In-app trial + license-key infrastructure** — track first-launch timestamp in Keychain; verify license keys cryptographically against a baked-in public key; surface the license state in Settings; hard-gate the panel when expired without a key.
3. **Key issuance tooling** — a shell script (`tools/issue-license-key.sh`) that takes a customer email + reads the Ed25519 private key from your Keychain (separate from the Sparkle key) and prints a license key you copy-paste into an email.

### License key cryptography

- **Algorithm**: Ed25519. Native on macOS via `CryptoKit.Curve25519.Signing`. No third-party dependency.
- **Keypair**: generated once, stored permanently. Private key → your local Keychain (account `drobu-license-ed25519`, distinct from the existing Sparkle key). Public key → 32 bytes of raw data baked into `Sources/DrobuCore/Info.plist` as a new `DrobuLicensePublicKey` field (base64-encoded), read at app launch.
- **License key format**: `DROBU-<base64url(payload)>.<base64url(signature)>`. Payload is 32 random bytes (effectively a UUID + extra entropy). Signature is the Ed25519 signature of those bytes by the private key. Total length ~110 characters — copy-pasteable, no whitespace issues.
- **Verification**: app base64url-decodes both halves, calls `Curve25519.Signing.PublicKey.isValidSignature(signature, for: payload)`. Constant-time inside the framework — no timing leaks. Pure offline check.
- **Storage of the active key**: Keychain (`com.danielius.ClipboardHistory.license`). Survives `defaults delete` and most pref-resets. Determined users can still extract and share; per the earlier audit, that's a separate concern accepted at this scale.

### Trial timestamp

- **Storage**: Keychain entry `com.danielius.ClipboardHistory.trial-start` with value = ISO8601 timestamp string. Written once on first launch if not already present; never updated thereafter.
- **Trial duration**: 14 days. After `trialStart + 14d`, the trial is "expired."
- **Why Keychain not UserDefaults**: surviving `defaults delete com.danielius.ClipboardHistory` is the bare-minimum tamper resistance for trial-extension attempts. Same pattern Sparkle uses for its key.

### Hard-gate behavior

- The floating clipboard panel (`FloatingPanel`) is the gated surface.
- When the user hits the hotkey (or clicks the menu-bar status item) and the trial is expired and there's no valid license, the panel **does not open**; instead, a smaller "Activation" panel opens with:
  - Headline: "Your 14-day trial has ended"
  - Subhead with one-time price and a "Buy Drobu" button → Stripe Payment Link
  - A `Paste license key` input field + "Activate" button
  - Footer link: "Already paid? Email support@... and we'll send your key."
- ClipboardMonitor continues running. SQLite history is preserved. Once a valid key is pasted, the panel works normally and history is intact.

## Implementation Units

### U1. Marketing copy update

**Goal**: every reference to subscription/$9.99/monthly in code is replaced with one-time/$14.99 wording. The 14-day-trial phrasing stays (the trial is now in-app, but customer-facing copy reads the same).

**Files**:
- `website/src/pages/terms.astro` — "$9.99/month with a 14-day free trial" → "$14.99 one-time purchase, with a 14-day free trial before purchase required."
- `website/src/components/Hero.astro` — "Start free trial" button label stays; the price subtext `$9.99/mo after 14-day free trial · macOS 14+ · Cancel anytime` → `$14.99 · 14-day free trial · macOS 14+`
- `website/src/components/DownloadCTA.astro` — same subtext fix as Hero
- `website/src/pages/privacy.astro` — review for monthly mentions; update if any
- `Sources/DrobuCore/Views/SettingsView.swift` — any About-section text mentioning the price

**Verification**: `grep -rn '9.99\|monthly\|subscription\|/mo\|recur' website/ Sources/` returns zero hits after the change (excluding unrelated string matches in code).

### U2. License-key keypair generation

**Goal**: produce the Ed25519 keypair, store the private key in Keychain, encode the public key for embedding.

**Files (new)**:
- `tools/generate-license-keypair.sh` — one-shot bash script using `openssl genpkey -algorithm ED25519` + `security add-generic-password` to write the private key to Keychain (`drobu-license-ed25519`). Prints the base64-encoded public key for copying into Info.plist. Idempotent guard: aborts if a key with that account already exists.

**Files (modified)**:
- `Sources/DrobuCore/Info.plist` — add `<key>DrobuLicensePublicKey</key><string>...</string>` with the base64-encoded 32-byte public key.

**Operational note**: this script runs **once, manually, by the developer** (not as part of the build). After running, you commit the new `Info.plist` value. The private key never enters the repo, never enters CI.

**Verification**: `security find-generic-password -a drobu-license-ed25519 -w` returns the private key. `Info.plist` contains a 44-character base64 string (32 bytes encoded).

### U3. LicenseManager Swift module

**Goal**: a single source of truth for trial state and license validation. `@MainActor`, `ObservableObject`, exposes a `LicenseStatus` enum the UI binds to.

**Files (new)**:
- `Sources/DrobuCore/Services/LicenseManager.swift` — public type with:
  ```swift
  enum LicenseStatus {
      case trialActive(daysRemaining: Int)
      case trialExpired
      case activated(email: String?)  // email nil for v1; reserved for future
  }

  @MainActor
  final class LicenseManager: ObservableObject {
      @Published private(set) var status: LicenseStatus
      func recordFirstLaunchIfNeeded()
      func activate(keyString: String) -> Result<Void, LicenseError>
      func deactivate()  // for testing only; not exposed in UI initially
  }
  ```
- `Sources/DrobuCore/Services/LicenseError.swift` — `enum LicenseError: malformed, badSignature, alreadyActivated`.

**Patterns to follow**:
- Mirror `CaptureHotkeyDefaults` for the singleton/load pattern (`Sources/DrobuCore/Models/CaptureHotkeyDefaults.swift`)
- Use `Security` framework's `SecItemAdd` / `SecItemCopyMatching` for Keychain access (no Sparkle-style wrapper). One helper function for each get/set/delete is enough; don't pull in a Keychain library.
- Read the public key from `Bundle.main.infoDictionary?["DrobuLicensePublicKey"]` on init; if missing, log error and fail-closed (treat as expired). Public-key absence in development should never silently allow access.

**Execution note**: write tests for `activate(keyString:)` first (TDD) — the cryptographic verification is the highest-stakes correctness path.

### U4. Trial state observation

**Goal**: `LicenseManager.recordFirstLaunchIfNeeded()` is called at app launch. The `LicenseStatus` updates reactively (Timer-driven, every hour) so a panel that's already open transitions to "expired" naturally if the user leaves the app running across the boundary.

**Files (modified)**:
- `Sources/DrobuCore/App/AppDelegate.swift` — instantiate `LicenseManager` early in `applicationDidFinishLaunching`. Call `recordFirstLaunchIfNeeded()`.

### U5. Settings UI: License section

**Goal**: a new section in `SettingsView` that shows current license status, lets users paste a key, and shows the price + Buy button if not activated.

**Files (modified)**:
- `Sources/DrobuCore/Views/SettingsView.swift` — add a `Section { ... } header: { Text("License") }`. Content depends on `licenseManager.status`:
  - **Trial active**: "Free trial — N days remaining" + "Buy Drobu — $14.99" link to Stripe URL + a collapsible "I already have a license key" disclosure with an input field
  - **Trial expired** (still active in this UI; not yet locked-out at app level — the gate is at panel show): same Buy button (emphasized) + license-key input always visible
  - **Activated**: "License activated" with a checkmark + a (subtle) "Reset license" button for testing

**Patterns**: mirror the existing About section for layout. Use `.onTapGesture` on `Text` for buttons (per `.claude/rules/swiftui-macos-gotchas.md` — buttons inside Form don't receive clicks).

### U6. Activation panel (the hard gate)

**Goal**: a small SwiftUI panel that opens instead of the clipboard `FloatingPanel` when the user hits the hotkey and the license check fails. Same look-and-feel as the clipboard panel, but content is the activation prompt.

**Files (new)**:
- `Sources/DrobuCore/Views/ActivationPanel.swift` — NSPanel subclass mirroring `FloatingPanel`'s structure (animation behavior, no-shadow, center-on-screen). Hosts an `ActivationView` SwiftUI view.
- `Sources/DrobuCore/Views/ActivationView.swift` — the SwiftUI surface: headline, price, Buy button, license key input field, Activate button. On successful activation, dismisses itself and lets the next hotkey press open the clipboard panel normally.

**Files (modified)**:
- `Sources/DrobuCore/App/AppDelegate.swift` `showPanel()` (line 175) — before constructing/showing `FloatingPanel`, query `licenseManager.status`. If `.trialExpired`, instantiate and show `ActivationPanel` instead and return early.

**Patterns to follow**:
- `Sources/DrobuCore/Views/FloatingPanel.swift` for the NSPanel subclass shape
- `Sources/DrobuCore/Views/SettingsView.swift` for SwiftUI form-style inputs

### U7. Key issuance shell script

**Goal**: a script you run on your laptop to manually generate a license key for each early customer. You email the key to them from your normal email until U-future automates this via a Stripe webhook.

**Files (new)**:
- `tools/issue-license-key.sh`:
  - Usage: `./tools/issue-license-key.sh <customer-email>`
  - Reads the Ed25519 private key from Keychain (`drobu-license-ed25519`)
  - Generates 32 random bytes as the payload
  - Signs the payload with the private key using `openssl pkeyutl -sign`
  - Outputs the formatted key `DROBU-<base64-payload>.<base64-sig>`
  - Appends a row to `tools/license-log.csv` (gitignored) with timestamp + email + payload-hex, so you have an audit trail for refunds/revocations
- `tools/license-log.csv` — gitignored.

**Files (modified)**:
- `.gitignore` — add `/tools/license-log.csv`

### U8. Tests

**Goal**: prove the cryptographic verification is correct and that trial-state transitions match expectations.

**Files (new)**:
- `Tests/DrobuTests/LicenseManagerTests.swift` — covering:
  - **Happy paths**: valid signature → activates; recording first launch → status is `.trialActive(14)`
  - **Edge cases**: trial day-13 → `.trialActive(1)`; trial day-14 exact → `.trialExpired`; trial day-15 → `.trialExpired`; activation while in trial → `.activated` (license takes precedence); empty license key string → `.malformed` error
  - **Error paths**: signature with one byte flipped → `.badSignature`; payload that's not base64url → `.malformed`; key in the wrong format (missing dot) → `.malformed`
  - **Integration**: full round-trip — script generates key, app verifies it, status flips to activated, gate doesn't fire

**Patterns**: follow `Tests/DrobuTests/TerminalTextCleanerTests.swift` shape (Swift Testing `@Test` / `@Suite`). Inject test keypair via a test-only init on `LicenseManager` so tests don't touch the real Keychain.

### U9. Documentation

**Goal**: future-you and any collaborator know how the license system works and how to issue keys for early customers.

**Files (new)**:
- `docs/licensing.md` — explains the cryptography, the issuance script's usage, the manual workflow for the first customers, and what the Stripe webhook automation will look like in the next phase
- Update `README.md`'s build section to mention the license-key system briefly (one paragraph)

## Files Modified Summary

| Path | Change |
|---|---|
| `website/src/pages/terms.astro` | Pricing copy → one-time / $14.99 |
| `website/src/pages/privacy.astro` | Review for stale monthly refs |
| `website/src/components/Hero.astro` | CTA subtext |
| `website/src/components/DownloadCTA.astro` | CTA subtext |
| `Sources/DrobuCore/Views/SettingsView.swift` | New License section + About-text fix |
| `Sources/DrobuCore/App/AppDelegate.swift` | Instantiate LicenseManager + gate `showPanel()` |
| `Sources/DrobuCore/Info.plist` | Add `DrobuLicensePublicKey` |
| `Sources/DrobuCore/Services/LicenseManager.swift` | **NEW** — license state + verification |
| `Sources/DrobuCore/Services/LicenseError.swift` | **NEW** — error type |
| `Sources/DrobuCore/Views/ActivationPanel.swift` | **NEW** — gated alternate panel |
| `Sources/DrobuCore/Views/ActivationView.swift` | **NEW** — activation form |
| `Tests/DrobuTests/LicenseManagerTests.swift` | **NEW** — coverage |
| `tools/generate-license-keypair.sh` | **NEW** — one-time keypair setup |
| `tools/issue-license-key.sh` | **NEW** — per-customer key issuance |
| `tools/license-log.csv` | gitignored, written by issue-license-key.sh |
| `docs/licensing.md` | **NEW** — operational docs |
| `.gitignore` | Add `/tools/license-log.csv` |

## Existing utilities reused

- `CryptoKit.Curve25519.Signing` — system framework, no dependency added
- `Security` framework Keychain APIs — already used implicitly via Sparkle's signing
- `Bundle.main.infoDictionary` — public-key lookup pattern matches existing version-read
- `FloatingPanel` shape — copy structure for `ActivationPanel`; do not subclass to keep the activation panel decoupled

## Verification

End-to-end smoke test, run after all units land:

1. **Keypair setup (one-time)**: run `tools/generate-license-keypair.sh`. Verify `security find-generic-password -a drobu-license-ed25519 -w` succeeds. Commit the new `Info.plist`.
2. **Fresh-install trial path**:
   - Reset customer state (procedure in the private support runbook)
   - Build + launch
   - Settings → License section shows "Free trial — 14 days remaining"
   - Hit hotkey → clipboard panel opens normally
3. **Trial-expired gate**:
   - Back-date the trial state (procedure in the private support runbook)
   - Hit hotkey → `ActivationPanel` appears, not `FloatingPanel`
   - Verify clipboard monitoring continues — copy some text, confirm it's in SQLite (`sqlite3 ~/Library/Application\ Support/ClipboardHistory/clipboard.sqlite`)
4. **License activation**:
   - `./tools/issue-license-key.sh test@example.com` → outputs a key
   - Paste into the ActivationPanel field → click Activate
   - Activation panel dismisses; hotkey now opens the clipboard panel again
   - Settings shows "License activated" with the captured email
   - The previously-captured clipboard items are visible (data preservation confirmed)
5. **Tamper resistance smoke**:
   - Modify one byte of the activated license key in Keychain
   - Restart Drobu
   - Verify status reverts to `.trialExpired` (since trial is also expired in this scenario) — confirms the verification rejects bad signatures on every check
6. **Stripe funnel end-to-end** (the actual real-money test):
   - Open `https://danieliusisiunas.github.io/drobu/` on the second laptop
   - Click "Start free trial" → land on Stripe Payment Link (now configured for one-time $14.99)
   - Pay with real card → land on thank-you page → download DMG → install
   - First launch: trial starts. App runs.
   - From this laptop: `./tools/issue-license-key.sh <your-customer-email>`
   - Email the key to yourself; paste it into Settings on the second laptop
   - Confirm activation succeeds and trial state becomes `.activated`

## Out of scope

These are real and worth doing, but **after** this plan lands:

- **Stripe webhook automation** — server-side service that listens for `checkout.session.completed`, generates a license key, and emails it. Cloudflare Worker (~50 lines) + email provider (Postmark / Resend free tier). Until this exists, you manually issue keys with the script above.
- **Revocation list** — if a customer charges back or you find a leaked key, a revocation list shipped with Sparkle updates lets new builds reject those keys. Not needed until you have evidence of abuse.
- **Per-device activation tracking** — current design has no device limit; one key works on any number of machines. Adding limits requires online activation (a backend) and is a v2 concern.
- **Refund handling** — Stripe handles the money; no automation on Drobu's side yet.
- **Recovery flow** — "I lost my key" customer support is manual email for now.
- **Major-version upgrade pricing** — v2 will be a separate decision when there's a v2 to ship.
- **Trial-extended-by-clearing-Keychain** mitigation — accepted; the bar is high enough for the indie scale.

## Risks & known limits

- **Keychain access prompts**: writing to Keychain on first launch may trigger a one-time macOS authorization dialog. Worth testing on a fresh user account to confirm the UX isn't surprising. If it is, fall back to UserDefaults with the understanding that trial-extension becomes easier.
- **`security` CLI in `issue-license-key.sh`**: assumes the developer's login keychain is unlocked when running the script. Document this in `docs/licensing.md`.
- **No test keypair in CI**: the test suite uses a generated-at-runtime test keypair; CI won't be reading from the real Keychain. Confirm Tests/DrobuTests can run without touching the developer's Keychain.
- **Cert trust + Sparkle key + License key** — three independent Keychain dependencies now. If you wipe Keychain, all three break. The `docs/licensing.md` runbook should call this out.
- **Self-signed app + license keys**: Gatekeeper warning on first install is unchanged; license activation is unaffected by it. Notarization (separate $99/yr Apple Developer Program) is still a future investment.
