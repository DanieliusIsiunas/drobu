# NSMenu / NSStatusItem Gotchas

## Live-updating an open NSMenu: `.common`-mode timer + title-only mutations

NSMenu tracking runs the run loop in `.eventTracking` mode. `Timer.scheduledTimer` registers in `.default` only, so it **does not fire while a menu is open** — countdowns and live status text freeze the moment the user opens the menu.

Fix: create the timer manually and register it in `.common`:

```swift
let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
    MainActor.assumeIsolated { self?.updateTitles() }
}
RunLoop.current.add(timer, forMode: .common)
```

Structural add/remove on an open NSMenu is an AppKit glitch vector (items can misrender or break tracking). The pattern that works (see the sleep-status section of `Sources/DrobuCore/App/AppDelegate.swift`):

- `menuWillOpen`: run any structural rebuild **before** setting the `isMenuOpen` flag, then create the `.common`-mode timer (invalidate any pre-existing one first)
- While open: update `item.title` only — never `menu.addItem` / `menu.removeItem`. To "remove" an expired item in place, set `item.submenu = nil` (an item with no action and no submenu auto-disables under `autoenablesItems`)
- `menuDidClose`: invalidate the timer, clear the flag, then run the structural rebuild to apply changes that arrived while open
- Guard delegate callbacks with `menu === statusItem?.menu` — submenu open events also hit the delegate

State-derived refresh beats transition-derived: recompute menu contents from current service state on every call (idempotent, order-independent), mirroring `refreshMenuBarBadge()`.

## Parent items with submenus

A parent `NSMenuItem` with `action: nil` and a non-nil `submenu` is always enabled under `autoenablesItems` (default) — no target/action needed for hover-to-open. Clicking the parent only opens the submenu, which makes it a safe "display + actions one hover away" pattern for status lines.

## NSMenuItem accessibility is free

`NSMenuItem.title` is the VoiceOver label — no explicit accessibility calls needed. Keep live-updating titles at **minute granularity**: per-second title changes make VoiceOver chatter on a focused item. Title changes while focused are not re-announced automatically (silent mutation; the user hears the current value on re-focus) — acceptable by design for countdowns.
