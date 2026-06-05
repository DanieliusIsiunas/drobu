---
date: 2026-06-05
topic: sleep-mode-menu-status-item
---

# Sleep Mode Menu Bar Status Item

## Summary

Add a status line to the menu bar menu for each active sleep mode — e.g. "Keep Awake — 23 min left" — hidden when nothing is active, ticking while the menu is open. Each line carries a submenu: Stop for both modes, plus Extend 1h for Keep Awake only.

## Key Decisions

- **Status line + submenu, not display-only and not click-to-stop.** The information stays safe from misclicks (clicking the status line only opens the submenu), while Stop and Extend remain one hover away.
- **Extend 1h is Keep Awake only.** Closed Lid's reversal time is baked into its privileged setup (`pmset disablesleep` + LaunchDaemon), so extending it requires redoing the admin-authenticated flow — a password prompt from a menu click. Closed Lid duration changes stay in `/sleep`.
- **Extend adds to remaining time.** "Extend 1h" means remaining + 1 hour (23 min left → 1 hr 23 min left), not a restart at 1 hour.

## Requirements

**Visibility**

- R1. When at least one sleep mode is active, the menu shows one status item per active mode at the top of the menu, above "Settings...", followed by a separator.
- R2. When no sleep mode is active, no status items appear — the menu keeps its current three items.
- R3. When both modes are active, both status items appear; Closed Lid is listed first, matching the badge-dot precedence.

**Content**

- R4. Each status item reads `<mode name> — <time remaining> left`, using the `/sleep` panel's mode names: "Keep Awake" and "Closed Lid".
- R5. Time remaining displays at minute granularity (e.g. "23 min left", "1 hr 5 min left"); below one minute it shows "< 1 min left".
- R6. The displayed time updates live while the menu is open.

**Actions**

- R7. Each status item's submenu contains "Stop", which ends that mode immediately — same effect as the `/sleep` panel's "Stop Keep Awake" / "Stop Closed Lid" actions.
- R8. The Keep Awake submenu additionally contains "Extend 1h", which adds one hour to the remaining time without any prompt.
- R9. The Closed Lid submenu contains only "Stop".

## Acceptance Examples

- AE1. **Covers R1, R4, R8.** Keep Awake active with 23 minutes remaining → menu shows "Keep Awake — 23 min left" with a Stop / Extend 1h submenu. Clicking Extend 1h changes the line to "1 hr 23 min left" with no prompt.
- AE2. **Covers R7, R9.** Closed Lid active → its submenu offers only Stop; clicking Stop ends the mode and removes the status item.
- AE3. **Covers R2.** No mode active → menu shows only Settings..., Check for Updates..., Quit.
- AE4. **Covers R3.** Both modes active → two status lines, Closed Lid first, each with its own submenu.

## Scope Boundaries

- Extend 1h for Closed Lid — deferred; revisit if the admin re-auth flow ever becomes promptless (e.g. pre-authorized helper).
- Multiple extend durations (15 min / 30 min picker) — single 1h action only.
- Countdown in the menu bar icon itself — the badge dot stays as is; time lives in the menu.

## Sources

- `Sources/DrobuCore/App/AppDelegate.swift` — `setupStatusItem()` builds the current menu; `refreshMenuBarBadge()` already reacts to both services' `onStateChange` callbacks.
- `Sources/DrobuCore/Services/CaffeinateService.swift` and `Sources/DrobuCore/Services/ClosedLidService.swift` — both expose `isActive`, `remainingTime`, and `onStateChange`; all data the menu needs already exists.
- `Sources/DrobuCore/Services/SleepCommand.swift` — source of the user-facing mode names and existing Stop actions.
