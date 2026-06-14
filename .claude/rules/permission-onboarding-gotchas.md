# Permission Onboarding Gotchas

Learned building the first-launch permission checklist (v1.7). Applies to any
future work on onboarding, the permission rows, or how Drobu introduces a TCC
permission.

## Never false-green Accessibility / Screen Recording — they need a restart

`AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` flip to `true` the
instant the user toggles the permission on, but the **functional** API
(`CGEventTap` for paste, the capture stream) does NOT work until the app
relaunches. Showing a green check at grant time is a lie — the next paste/capture
still fails.

**Rule (in `PermissionsService`):** snapshot a *launch baseline* of each
permission's granted-state at startup. A restart-requiring permission is:
- `.granted` only if it was granted **at launch** (works now),
- `.pendingRestart` if it was NOT granted at launch but is granted now (needs a
  relaunch — show amber "Restart to activate", offer a Restart button),
- `.notGranted` otherwise.

Non-restart permissions (Pasteboard, the Closed Lid daemon, Launch-at-Login)
never enter `.pendingRestart`. The whole rule is a pure function of
`(grantedAtLaunch, grantedNow, requiresRestart)` — keep it that way so it's
unit-testable with a mock probe (the real APIs stay out of test scope). Create
the single `PermissionsService` instance **early** in
`applicationDidFinishLaunching` so the baseline reflects launch, not some later
point.

## Which permissions get a dialog vs. a trip to System Settings

- **Accessibility, Screen Recording, Input Monitoring:** no in-app system
  dialog on macOS 13+. You must deep-link to the System Settings pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  / `?Privacy_ScreenCapture`) and let the user toggle it. For Screen Recording,
  call `CGRequestScreenCaptureAccess()` first so Drobu is *in the list* before
  the deep-link (otherwise the toggle may not exist yet).
- **Microphone, Camera:** direct system dialog (Drobu uses neither —
  `capturesAudio = false`).
- Because there's no notification when these are granted, the onboarding panel
  re-polls on `NSApplication.didBecomeActiveNotification` **and** a
  `.common`-mode timer (the proven `SettingsView` daemon-row pattern) so rows
  flip live when the user returns from System Settings.

## Detecting Screen Recording status without prompting — and the "Menubar" false-positive

There is **no** reliable, non-prompting, synchronous "is Screen Recording
granted" API. The two candidates each fail one way:

- `CGPreflightScreenCaptureAccess()` — non-prompting, but has documented
  **false-negatives** on macOS 15+ (returns `false` even when granted; it's why
  `ScreenCaptureService` never *gates* capture on it — see line 37). Trust a
  `true` reading (no false positives); a `false` reading is inconclusive.
- **Window-name redaction** — without the grant, macOS redacts *other apps'*
  window **titles** (`kCGWindowName` is empty). So a visible foreign title is a
  positive signal. BUT this is only true for **normal app windows
  (`kCGWindowLayer == 0`)**. System chrome keeps readable titles regardless of
  the grant — most dangerously **Window Server's "Menubar" window (layer 24)**,
  which is always on screen. An unfiltered "any foreign window has a name" check
  therefore **always returns true** → the Screen Recording row false-greens for a
  process that has no access (shipped bug, caught live 2026-06-14: row showed
  green, capture still threw the system "would like to record" prompt). `SCShareableContent`
  is the gold-standard check but is async AND **prompts** when ungranted, so it
  must never run on the onboarding poll.

**Rule:** `granted = CGPreflightScreenCaptureAccess() || (any foreign window with
windowLayer == 0 and a non-empty name)`. The layer-0 filter is load-bearing —
verify any change to it against a process that genuinely lacks the grant (the
`swift` CLI is one: it'll show `CGPreflight=false` and, correctly, zero foreign
layer-0 names while still seeing "Menubar"). Logic lives in
`screenRecordingGrantedFromWindows` (pure, unit-tested); the `CGWindowListCopyWindowInfo`
syscall stays in `SystemPermissionProbe.onScreenWindowOwnership`. Known accepted
limitation: a just-toggled-on-but-not-yet-restarted grant reads as not-granted
(both signals stay false until the process restarts) — honest (capture genuinely
doesn't work yet), and strictly better than a false green.

## Pasteboard (macOS 15.4+): read `accessBehavior`, never trigger the alert-storm

Detect via the reflective `NSPasteboard.general.value(forKey: "accessBehavior")`
KVC read; the selector being absent means the OS is < 15.4 → the row is
`.notApplicable` and simply not shown. **Status detection** (the live poll +
focus re-check) must only **read** `accessBehavior` — never read pasteboard
*content* in the detection path, or you'd trip the per-access "Allow Paste"
system alert on every poll (which the 0.5s clipboard poll already fires often
enough).

The **user-initiated row action** is the one exception, and it's required: on a
fresh 15.4+ install System Settings lists an app under Pasteboard only after it
has attempted a programmatic content read (the read is what surfaces the alert
and registers the app). The 0.5s monitor only reads on a *change*, so a user who
clicks "Open Settings" before copying anything lands on a pane where Drobu isn't
listed — a dead end. So the pasteboard action does ONE deliberate content read
(`OnboardingActuator.primePasteboardAccess`) to register Drobu + surface the
grant alert *before* deep-linking. This mirrors the Screen Recording action
calling `CGRequestScreenCaptureAccess()` before its deep-link. One tap = one
read is fine; it's the passive per-poll read that must never happen.

**`accessBehavior` raw values matter — `0` is NOT "granted".** The SDK enum
(`NSPasteboardAccessBehavior`, verified against the macOS 15.4+ headers) is
`default = 0`, `ask = 1`, `alwaysAllow = 2`, `alwaysDeny = 3`. **Only
`alwaysAllow` (2) is an affirmative grant** — the state where programmatic reads
succeed silently. `default` (0) is the *prompt-on-access* state, so treating
`== 0` as granted (the original, repo-wide assumption in `ClipboardMonitor` /
`checkPasteboardPrivacy`) **false-greens fresh installs** and suppresses the
guidance alert when reads actually fail. The single source of truth is
`pasteboardAccessGranted(rawAccessBehavior:)` → `raw == 2`, used by
`NSPasteboard.drobuAccessGranted` (`Sources/DrobuCore/Services/SystemPrivacy.swift`).
The denial path stays safe because the alert is double-gated: it fires only when
`pasteboardItems` is *also* nil (a real read failure), not merely on `!= 2`.

## Host onboarding in an ActivationPanel-model floating NSPanel — NOT a Settings/Window scene

A SwiftUI `Settings`/regular `Window` scene reintroduces the documented
Settings-scene traps (`.alert`/`.confirmationDialog` don't fire, `NSApp.delegate`
is nil under `.regular`) and forces the `.accessory ↔ .regular` activation-policy
juggling. A floating `NSPanel` modeled on `ActivationPanel` (AppDelegate-owned,
`canBecomeKey = true`, app stays `.accessory`, recreated each show) sidesteps all
of it and can reach the delegate directly. The Settings/menu re-entry points open
this same panel via a `NotificationCenter` post (the delegate observes it) since
`SettingsView` can't reach the delegate.

## Reuse the daemon-row remediation; don't reinvent the priming UX

The Closed Lid row's "enable" action is just `DaemonRegistrar().remediate()` —
which already encodes the state-correct rule (`.notFound` means **register
first**; only `.requiresApproval` deep-links to Login Items, never to a toggle
that doesn't exist yet). The status-glyph + contextual-action + re-check-on-focus
shape of the whole checklist is generalized straight from the existing
`SettingsView` "Closed Lid Mode" section — that section is the in-repo gold
standard for permission priming.

## First-run gate: a UserDefaults flag, not the trial Keychain key

Track "has completed onboarding" with a dedicated `UserDefaults` flag
(`OnboardingGate`). Do NOT overload the licensing `trial-start` Keychain key —
it's load-bearing for the trial clock and the clock-rollback anchor. Any
dismissal of the panel (Start / Skip / close button) marks completed, so it never
auto-nags again; Settings/menu re-entry bypasses the gate.
