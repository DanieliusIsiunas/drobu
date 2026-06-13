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

## Pasteboard (macOS 15.4+): read `accessBehavior`, never trigger the alert-storm

Detect via the reflective `NSPasteboard.general.value(forKey: "accessBehavior")`
KVC read (`== 0` means unrestricted/granted; the selector being absent means the
OS is < 15.4 → the row is `.notApplicable` and simply not shown). Onboarding must
only **read** this — never call a paste-access API from onboarding, or you'd
trip the per-access "Allow paste" system alert (which the 0.5s clipboard poll
already fires often enough).

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
