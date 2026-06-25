# SwiftUI macOS Gotchas

## Settings Scene

The `Settings` scene switches activation policy: `.accessory` → `.regular` (open) → `.accessory` (close).

- **Buttons don't receive clicks** inside grouped `Form`. Use `Text` + `.onTapGesture` instead of `Button`.
- **`NSApp.delegate as? AppDelegate` returns nil**. Access shared resources directly (e.g. `AppDatabase()`).
- **`.alert` / `.confirmationDialog` actions silently never fire**. Use `NSAlert.beginSheetModal(for: NSApp.keyWindow!)`.

## NSPanel + SwiftUI

- `onAppear`/`onDisappear` don't reliably fire for SwiftUI views in `NSHostingView`. Recreate the panel each time.
- Use `WeakFloatingPanel` wrapper for environment keys to avoid retain cycles.
- `animationBehavior = .none` makes `close()` instant. Don't use `alphaValue = 0` with `NSVisualEffectView`.

## We do NOT use the `Settings` scene anymore — Settings is an AppDelegate-owned NSPanel (v1.8)

The whole "Settings Scene" section above is the list of traps we **escaped** by
deleting the SwiftUI `Settings` scene. As of v1.8 (`SettingsPanel`), Settings and
first-run onboarding are ONE floating `NSPanel` owned by `AppDelegate` (the
`OnboardingPanel` model: `canBecomeKey`, app stays `.accessory`, recreated each
show). Consequences worth remembering:

- **No more activation-policy dance.** The old flow needed a hidden 0×0
  "settings-opener" `Window` that owned `@Environment(\.openSettings)` and toggled
  `.accessory`↔`.regular` on open/close. All deleted — the panel reaches the
  delegate directly and the app never leaves `.accessory`.
- **A SwiftUI `App` still needs one `Scene`.** `DrobuApp` keeps an inert
  `Settings { EmptyView() }` placeholder that is never presented (the status
  menu's "Settings…" item / ⌘, calls `AppDelegate.showSettings()` directly, and
  the `/settings` slash command posts `.openSettingsFromMenu` which the delegate
  observes). Verified: the placeholder does not auto-present a window or steal ⌘,
  under `.accessory`. Do NOT re-add a real `Settings { SettingsView() }` scene —
  it reintroduces every trap above.
- **`.alert`/`.confirmationDialog` now work** (we're not in a Settings scene), but
  we kept `NSAlert.beginSheetModal(for: NSApp.keyWindow!)` for the destructive
  confirmations because the uninstall sheet needs an `NSButton` checkbox
  `accessoryView` SwiftUI dialogs can't host. The panel `canBecomeKey`, so
  `NSApp.keyWindow` resolves to it when a sheet is presented.
- **Sidebar selection accessibility:** sidebar rows are `Text + .onTapGesture`, so
  each needs `.accessibilityElement(children: .ignore)` + label + `.isButton`, and
  the selected row adds `.isSelected` (see `.claude/rules/accessibility.md`).
- **One panel, two modes:** `firstRun` (from `OnboardingGate.shouldAutoShow`) picks
  the landing section and whether the Set Up pane shows welcome/CTA chrome — all
  via the pure, tested `SettingsNavigationModel` (`landingSection`/
  `showsWelcomeChrome`). `OnboardingView` takes a `presentation` mode so the same
  checklist serves first-run onboarding and the revisitable "Set Up" section.

## Settings rows go through `settingsRow` + `actionLink` — keep the label column plain (v1.9.3)

Every Settings pane (Shortcuts, History, License, About) uses one row grammar:
**label (+ optional description) on the left, action/control on the right.** Two
private builders in `SettingsView` own it — do NOT hand-roll an `HStack` row:

- `settingsRow(_:description:verticalAlignment:trailing:)` — leading `VStack`
  (label + optional `.caption` description) / `Spacer(minLength:)` / trailing slot.
  Default `verticalAlignment` is `.firstTextBaseline` (text actions align to the
  label's first line, not a wrapped description); pass **`.center`** for a bordered
  trailing control (hotkey recorder, text field) or it sits visually low.
- `actionLink(_:destructive:a11yLabel:action:)` — inline action for the trailing
  slot, rendered as an always-on tinted **pill** via `.actionPill(_:)` (see the
  v1.9.5 pill section below). Bundles the clickable affordance + the VoiceOver trio
  (`.accessibilityElement(children:.ignore)` + label + `.isButton`), so a11y can't
  be forgotten per-site. Append `.accessibilityHint(_:)` at the call site for the
  few actions that need one. The pill sets its own font (12pt semibold).

**The leading column MUST stay plain, non-padded `Text`.** That is the whole
alignment fix: `hoverHighlight()` adds `+7pt` horizontal padding, so if a label
ever carries it (the old per-site pattern), the label indents out of line with
descriptions/other rows. Labels never get the affordance padding; only the
trailing `actionLink` pill does.

**A `settingsRow` `description:` is read by VoiceOver** (it's a plain `Text`, not
hidden) — that's correct for informative copy (mirrors the History retention
caption). So a trailing action's `.accessibilityHint` must add only what the
visible description does NOT say (e.g. "A confirmation appears first."), never
restate it — or VoiceOver speaks the same content twice (caught in the v1.9.3
review on the About "Uninstall" row).

Deliberate non-members: `licenseStatusRow` (value display, not actions — now
rendered with `statusPill` chips) and the History retention field rows (composite
control+unit trailing). Leaving those hand-rolled is intentional, not an oversight.
(The Set-Up "Remove Closed-Lid Helper" action is no longer a hand-rolled bottom-of-
pane orphan — as of v1.9.5 it's the trailing action on the Closed-lid keep-awake
row; see the pill section below.)

## Settings actions & status are tinted pills, not bare colored text (v1.9.5)

The Settings panel sits on `.regularMaterial` (translucent), so its effective
background is the user's wallpaper. Bare saturated `Text` actions (`Color.red`,
`Color.accentColor`) lose contrast on a light/medium wallpaper — the shipped 1.9.4
complaint ("Deactivate" / "Delete" / "Buy" hard to read). Fix: every inline action
is an **always-on tinted capsule** that carries its own contrast regardless of
wallpaper.

- One shared file, `Sources/DrobuCore/Views/ActionPill.swift`: `SettingsPillRole`
  (`neutral` / `destructive` / `success` / `warning`), the `ActionPill` view
  modifier, and `View.actionPill(_:enabled:)`. Used by BOTH `SettingsView`
  (`actionLink`, `statusPill`) and the Set-Up pane (`OnboardingView.actionControl`)
  so every action across the window reads the same.
- **Red is reserved for destructive actions only** (Delete, Uninstall, Remove
  helper). Neutral safe actions (Deactivate, Buy, Activate, Paste, Open Settings,
  Enable) are **calm grey** (`.neutral` = `Color.primary` text). Coral was rejected
  for neutral — too close to red, it muddies the danger signal. Status is a chip via
  `statusPill`: green Activated / amber limit-reached / red Expired·Refunded.
- Fill opacity is a flat `0.30` (`0.37` on hover) of the role color — strong enough
  to lift text off a variable wallpaper while staying calm. (Started at 0.12–0.16;
  bumped to 0.30 after live review on a light wallpaper.)
- `statusPill` is intentionally NOT composed on `ActionPill` — it's non-interactive
  (no hover, no `.contentShape`, no `.isButton`). A status chip must not look or
  behave like a button.
- `ActionPill` ends with `.allowsHitTesting(enabled)` so a disabled pill is inert at
  the modifier level — the disabled contract doesn't depend on each call site
  remembering to guard its `.onTapGesture`.
- The Closed-lid checklist row is **status-only**, exactly like the other
  permissions: "Enable" when not set up, "Ready" when set up — no inline teardown.
  (An earlier "Remove" trailing action there was the lone row that broke the
  status-checklist scan — every other granted row just reads "Ready" — so it was
  rejected for consistency. Closed-lid is the *only* Drobu-installed helper among
  the rows; the others are OS-managed TCC grants Drobu can't un-grant anyway.)
  Removing the privileged helper lives in **About → Danger Zone** ("Remove
  Closed-Lid Helper", shown only while `daemonStatus == .enabled`), next to Uninstall
  where teardown belongs. `SettingsView.removeClosedLidHelper()` mirrors
  `UninstallService`'s R14 ordering — `DaemonClient().disableBounded()` +
  `resetConnection()` BEFORE `DaemonRegistrar().unregister()` — so an active
  session's `pmset disablesleep` is reversed first and never stranded.
- Separators: every pane uses a plain `Divider()` between blocks (the License pane
  had none before v1.9.5); the old per-site `.padding(.top, 6)` divider tweak in
  History was retired.
