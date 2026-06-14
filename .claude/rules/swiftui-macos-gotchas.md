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
