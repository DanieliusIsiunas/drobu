---
title: "feat: Sleep mode status items in menu bar menu"
type: feat
status: completed
date: 2026-06-05
origin: docs/brainstorms/2026-06-05-sleep-mode-menu-status-item-requirements.md
---

# feat: Sleep Mode Status Items in Menu Bar Menu

## Summary

Add a status line to the menu bar menu for each active sleep mode — "Keep Awake — 23 min left" / "Closed Lid — 1 hr left" — hidden when nothing is active, with a live countdown while the menu is open. Each line carries a submenu: Stop for both modes, Extend 1h for Keep Awake only.

## Requirements

Carried from origin (see origin: docs/brainstorms/2026-06-05-sleep-mode-menu-status-item-requirements.md):

**Visibility**

- R1. One status item per active sleep mode at the top of the menu, above "Settings...", followed by a separator.
- R2. No status items when no mode is active — the menu keeps its current three items.
- R3. Both modes active → both items shown, Closed Lid first (matches badge-dot precedence).

**Content**

- R4. Title format `<mode name> — <time remaining> left`, using "Keep Awake" / "Closed Lid".
- R5. Minute-granularity time ("23 min left", "1 hr 5 min left"); below one minute "< 1 min left".
- R6. Displayed time updates live while the menu is open.

**Actions**

- R7. Each submenu has "Stop", ending that mode immediately — same effect as the `/sleep` panel's stop actions.
- R8. Keep Awake submenu adds "Extend 1h": remaining time + 1 hour, no prompt.
- R9. Closed Lid submenu contains only "Stop".

Origin acceptance examples AE1–AE4 apply unchanged.

## Key Technical Decisions

- **State-derived menu refresh through the existing `onStateChange` callbacks.** A single helper rebuilds the status items by reading `isActive` + `remainingTime` at call time, invoked from both services' `onStateChange` (alongside `refreshMenuBarBadge()`) and from `menuWillOpen`. Mirrors the idempotent, order-independent pattern of `refreshMenuBarBadge()` (`Sources/DrobuCore/App/AppDelegate.swift`). No third callback mechanism.
- **Countdown timer in `.common` run-loop mode, scoped to menu visibility.** Default-mode timers do not fire while NSMenu tracking runs the loop in `.eventTracking` — the countdown would freeze the moment the menu opens. Create a 1s repeating timer in `menuWillOpen` added via `RunLoop.current.add(timer, forMode: .common)` (idiom from `Sources/DrobuCore/Services/ClipboardMonitor.swift`), invalidate in `menuDidClose`. Timer closure uses `[weak self]` + `MainActor.assumeIsolated`, matching repo convention.
- **Extend composes existing primitives: `extend(by:)` on CaffeinateService calls `start(duration: remainingTime + 3600)`.** `start()` already handles replacing a running session safely (terminates old process without terminationHandler races). `startDate` resets but remaining-time math holds. Guard on `isActive`; extend on an inactive service is a no-op.
- **Visibility gated on `isActive && (remainingTime ?? 0) > 0`, never `state`.** `CaffeinateService.isActive` short-circuits once remaining time hits 0, but `ClosedLidService.isActive` is just `state != .idle` — after expiry it stays true for up to 30s (reconciliation lag). Gating on the combined check avoids a stale "< 1 min left" line for both modes.
- **Formatter is a static pure function next to `formatDuration` in `SleepCommand`.** Keeps duration formatting in one place; static pure functions are directly testable per repo testing conventions.
- **Stop actions call the services directly** (`caffeinateService.stop()` / `closedLidService.stop()`), mirroring `SleepCommand.execute` (`ka-cancel` / `cl-cancel` paths). The resulting `onStateChange` fires the menu refresh — no manual item removal needed.

## Assumptions

- Extend restarts the underlying `caffeinate` process with a new total; the brief process replacement is invisible to the user since remaining time is preserved by computation.
- `SleepCommand` enforces mutual exclusion between modes today, so both-active (R3) is a defensive case; iterating both services handles it at no extra cost.
- The countdown timer ticks at 1s while the menu is open; the displayed string changes at minute granularity (R5), which also avoids per-second VoiceOver announcements on a focused item.
- Status parent items are enabled (required for submenu hover) but carry no action of their own — clicking the parent only opens the submenu, per the origin's misclick-safety decision.
- Clicking Stop closes the menu (standard NSMenu click behavior), so no disabled-state choreography is needed during teardown; `stop()` is idempotent if invoked twice.
- Countdown title updates are silent for VoiceOver by design — no accessibility announcement is posted per tick (would be chatter); a VoiceOver user hears the current value when (re)focusing the item.

---

## Implementation Units

### U1. Remaining-time formatter

- **Goal:** Pure function turning a `TimeInterval` into the menu's human phrasing.
- **Requirements:** R4, R5.
- **Dependencies:** none.
- **Files:** `Sources/DrobuCore/Services/SleepCommand.swift` (add static alongside `formatDuration`), `Tests/DrobuTests/SleepCommandFormattingTests.swift` (new).
- **Approach:** `static func formatRemaining(_ seconds: TimeInterval) -> String`. Floor to whole minutes. Returns the complete phrase including `" left"`: under 60s → `"< 1 min left"`; under an hour → `"N min left"`; on the hour → `"N hr left"`; otherwise → `"N hr M min left"`. U3 builds titles as `<mode name> — <formatRemaining(...)>` with no further suffix.
- **Patterns to follow:** `SleepCommand.formatDuration` (static, pure); `Tests/DrobuTests/TerminalTextCleanerTests.swift` for `@Test(arguments:)` parameterized style.
- **Test scenarios:**
  - Covers AE1 (display shape). 0s and 59s → "< 1 min left"; 60s → "1 min left"; 90s → "1 min left" (floor); 1380s → "23 min left".
  - 3600s → "1 hr left"; 3900s → "1 hr 5 min left"; 7200s → "2 hr left"; 7260s → "2 hr 1 min left".
- **Verification:** `swift test` passes with the new parameterized suite.

### U2. CaffeinateService.extend(by:)

- **Goal:** Add one hour to an active Keep Awake session without prompting.
- **Requirements:** R8.
- **Dependencies:** none.
- **Files:** `Sources/DrobuCore/Services/CaffeinateService.swift`, `Tests/DrobuTests/CaffeinateServiceTests.swift`.
- **Approach:** `func extend(by interval: TimeInterval)` — guard `isActive` and a non-nil `remainingTime`, then `start(duration: remaining + interval)`. Log the action (`Log.info("CaffeinateService: extended by ...")`), no clipboard/user data involved.
- **Patterns to follow:** existing `CaffeinateServiceTests` suite (`@MainActor @Suite`, `defer { service.cleanup() }`, `start(duration: 0)` trick for deterministic expiry).
- **Test scenarios:**
  - Extend while active with duration 600 → `remainingTime` > 4100 (lower-bound assertion only — wall clock elapses during the test); `isActive` stays true.
  - Extend when idle → state stays `.idle`, no process spawned.
  - Extend after expiry (`start(duration: 0)`, `isActive == false`) → no-op, still inactive.
  - `onStateChange` fires on extend (state transitions to a fresh `.active`).
- **Verification:** `swift test` passes; no orphaned `caffeinate` processes after the suite (cleanup in `defer`).

### U3. Dynamic status items in the menu bar menu

- **Goal:** Status lines with Stop / Extend submenus, live countdown, shown only while a mode is active.
- **Requirements:** R1–R9 — U3 wires all display and action behavior; U1 supplies the R5 formatter, U2 supplies the R8 extend method.
- **Dependencies:** U1, U2.
- **Files:** `Sources/DrobuCore/App/AppDelegate.swift`.
- **Approach:** Keep a reference to the menu (or its status-section items). A `refreshSleepStatusItems()` helper removes prior status items and inserts current ones at index 0 (Closed Lid first, then Keep Awake, then a separator — only when at least one mode is active). Parent items get a submenu: "Stop" (`@objc` selectors calling `caffeinateService.stop()` / `closedLidService.stop()`), plus "Extend 1h" (`caffeinateService.extend(by: 3600)`) on the Keep Awake submenu only. Hook the helper into both `onStateChange` closures next to `refreshMenuBarBadge()`. AppDelegate conforms to `NSMenuDelegate` and assigns `menu.delegate = self` in `setupStatusItem()` (no delegate exists on the menu today): `menuWillOpen` refreshes titles and starts the 1s `.common`-mode timer (invalidating any pre-existing timer first); `menuDidClose` invalidates it and runs a structural rebuild. While the menu is open, the timer updates titles only — no structural add/remove during tracking (a known AppKit glitch vector). If a mode expires mid-display, the timer disables that item and its submenu in place; removal happens at the next closed-state refresh. `refreshSleepStatusItems()` skips structural rebuild while the menu is open (track open state via the delegate callbacks).
- **Patterns to follow:** `setupStatusItem()` menu construction and `@objc` selector targets (`AppDelegate.swift`); `.common`-mode timer registration from `ClipboardMonitor.swift`; `MainActor.assumeIsolated` timer-closure convention (`ClosedLidService` reconciliation timer).
- **Test scenarios:** Test expectation: none — AppKit menu wiring (NSStatusItem/NSMenu), excluded per `.claude/rules/testing-conventions.md`.
- **Verification:** Build and run. With no mode active the menu shows the original three items (AE3). Start Keep Awake via `/sleep` → status line with Stop + Extend 1h appears (AE1); countdown ticks with the menu held open (R6). Extend 1h adds an hour with no prompt (AE1). Start Closed Lid → its submenu offers only Stop (AE2); Stop removes the line (AE2). VoiceOver reads item titles natively.

---

## Scope Boundaries

Carried from origin:

- Extend 1h for Closed Lid — deferred (admin re-auth prompt from a menu click).
- Multiple extend durations — single 1h action only.
- Countdown in the menu bar icon itself — badge dot unchanged.

## Sources & Research

- `Sources/DrobuCore/App/AppDelegate.swift` — `setupStatusItem()`, `refreshMenuBarBadge()` (state-derived refresh pattern), `onStateChange` wiring in `applicationDidFinishLaunching`.
- `Sources/DrobuCore/Services/CaffeinateService.swift`, `Sources/DrobuCore/Services/ClosedLidService.swift` — `isActive` / `remainingTime` semantics and the expiry-to-cleanup gap.
- `Sources/DrobuCore/Services/SleepCommand.swift` — mode names, stop-action calls to mirror, `formatDuration` placement.
- `Sources/DrobuCore/Services/ClipboardMonitor.swift` — `.common`-mode timer registration idiom.
- `Tests/DrobuTests/CaffeinateServiceTests.swift`, `Tests/DrobuTests/TerminalTextCleanerTests.swift` — test suite patterns to extend.
