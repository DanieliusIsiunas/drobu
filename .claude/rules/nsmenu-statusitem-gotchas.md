# NSMenu / NSStatusItem Gotchas

## A status badge driven by `onStateChange` needs a deadline trigger, not just a process/callback (v1.9.6)

The menu-bar sleep dot is refreshed only from `CaffeinateService`/`ClosedLidService`
`onStateChange` (→ `AppDelegate.refreshStatusIcon`, which reads `currentSleepMode`
← each service's `isActive`). The trap: `isActive` is **computed and
deadline-aware** (`CaffeinateService.isActive` returns false once `remainingTime
<= 0`), but `state` (the thing whose `didSet` fires `onStateChange`) flipped to
`.idle` **only when the OS `caffeinate` process terminated** — its
`terminationHandler`. Those two diverge: at the logical deadline `isActive`/the
menu say "expired" while `state` is still `.active`, and **nothing re-evaluates
the badge in that window** (the 1 Hz menu timer runs only while the menu is open
and only mutates titles). So the green dot persisted after keep-awake expired —
worst across system sleep, where the suspended `caffeinate` process outlives its
`-t` and the termination callback's main-actor hop doesn't run until wake (shipped
bug, v1.9.5).

**Rule:** any status driven by a push (`onStateChange`) whose underlying truth is
a computed deadline-aware flag must have a **deadline trigger** that pushes at the
deadline — don't rely on an OS process/callback that can lag it. Fix
(`CaffeinateService.scheduleExpiry` + idempotent `reconcileExpiry`): a one-shot
`.common`-mode `Timer` at the deadline calls `reconcileExpiry()`, which ends the
session (→ `state = .idle` → `onStateChange` → badge clears). `.common` so it fires
during menu tracking; a one-shot whose fire date passed during sleep fires **on
wake**, which is when you want to reconcile. `reconcileExpiry` is guarded
(`active && remaining <= 0`) so it's safe to call any time. `ClosedLidService`
already had this shape (its 30 s `reconcileTick`); `CaffeinateService` did not —
that asymmetry was the bug.

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

## Status-item badge subviews: `y = 1` renders at the TOP edge

When overlaying a badge (a colored dot, an SF Symbol) as a subview of
`statusItem.button` with a fixed `NSRect`, **small y is the TOP of the button,
not the bottom** — the status button's content coordinate space is effectively
flipped relative to a plain bottom-left-origin `NSView`. Verified visually
(v1.9.2): the sleep dot at `y: 1` rendered at the **top**-right; moving it to
`y: button.bounds.maxY - height` put it at the **bottom**-right.

This bit us once: the gentle-update arrow was placed at `y: maxY - size` intending
"top-right," but that's actually the **bottom**, so it landed diagonally wrong
from the design (and the code comments claimed the opposite corner). Rule for two
coexisting badges (e.g. Drobu's sleep dot + update arrow):
- **Top-right:** `NSRect(x: maxX - w - 1, y: 1, …)`
- **Bottom-right:** `NSRect(x: maxX - w - 1, y: maxY - h, …)`

They share the right edge but sit at opposite y-extremes, so they never overlap.
Don't reason about the orientation from "NSView is bottom-left origin" — for the
status button it behaves top-down; calibrate against a known-visible badge (or
just build + look) before trusting a corner.
