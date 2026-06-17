---
title: "feat: Discreet (gentle) Sparkle update reminders"
type: feat
date: 2026-06-17
status: planned
---

# feat: Discreet (gentle) Sparkle update reminders

## Summary

Drobu currently uses Sparkle's default `SPUStandardUserDriver` with no delegates wired, so a background scheduled check that finds an update pops a **modal window at an arbitrary moment** — jarring for a `.accessory` menu-bar app. This plan replaces that with Sparkle's first-class **gentle reminders** pattern (the Ollama-style flow): updates download silently in the background, and a waiting update is surfaced only through (a) two status-menu items — a disabled `Update available — vX.Y.Z` line plus an actionable `Restart to Update` — and (b) a small blue down-arrow glyph on the menu-bar icon. User-initiated "Check for Updates…" keeps its normal dialog. No interrupting modal for background checks.

This touches the release-critical Sparkle path, so the hard invariants are preserved verbatim: `SUPublicEDKey`, `SUFeedURL`, EdDSA verification, and the notarization/staple flow are unchanged.

---

## Problem Frame

- **Today:** `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` (`Sources/DrobuCore/App/AppDelegate.swift:172-177`). With `SUEnableAutomaticChecks=true` and **no** `SUAutomaticallyUpdate`, a background check that finds an update presents Sparkle's standard modal whenever it lands, and the bits aren't pre-downloaded.
- **Want:** the discreet pattern users expect from a background utility (Ollama, many Sparkle apps): silent background download, then a quiet, discoverable signal the user acts on when *they* choose.
- **Mechanism:** Sparkle ≥2.2 "gentle reminders" (we ship 2.9.1). An `SPUStandardUserDriverDelegate` lets us suppress the modal for *scheduled* presentations and surface our own UI instead, while user-initiated checks still show the standard dialog.

Reference: <https://sparkle-project.org/documentation/gentle-reminders/> (the dock-badge / `setActivationPolicy(.regular)` bits in that example are **omitted** — Drobu has no dock icon; our surfaces are the status menu + status-item icon only).

---

## Requirements

- **R1** — A background/scheduled update check must NOT present a modal window.
- **R2** — A user-initiated "Check for Updates…" MUST still present Sparkle's standard dialog (results expected).
- **R3** — A waiting (downloaded) update is surfaced as: a disabled informational menu item `Update available — vX.Y.Z` and an actionable `Restart to Update` item that resumes the install + relaunch.
- **R4** — A waiting update is also surfaced as a small blue down-arrow glyph in the **top-right** of the menu-bar icon, which must coexist with the existing green/orange sleep dot in the **bottom-right** without visual or code collision (both can show simultaneously).
- **R5** — Updates download silently in the background so "Restart to Update" applies near-instantly.
- **R6** — The release-critical Sparkle contract is unchanged: `SUPublicEDKey`, `SUFeedURL`, EdDSA verification, notarization/staple flow.
- **R7** — New pure decision logic (menu title from version, icon-indicator coexistence) ships with Swift Testing tests in the same commit. AppKit/Sparkle wiring is verified manually, not unit-tested (per `.claude/rules/testing-conventions.md`).
- **R8** — VoiceOver: new menu items carry correct titles (free label); the status-item button accessibility label reflects "update available" when pending.

---

## High-Level Technical Design

### Gentle-reminder behavior matrix

`standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` fires **only for scheduled (automatic) presentations** — user-initiated checks bypass it entirely and always show Sparkle's UI.

| Trigger | Delegate signal | Our behavior | Modal? |
|---|---|---|---|
| Background scheduled check, app NOT frontmost | `shouldHandleShowingScheduledUpdate(_, andInImmediateFocus: false)` | return **`false`** (suppress) | No |
| Background scheduled check, app IS frontmost | `…andInImmediateFocus: true` | return **`true`** (user is present; let Sparkle show) | Yes |
| Scheduled update suppressed → presentation hook | `willHandleShowingUpdate(_, forUpdate:, state:)` with `state.userInitiated == false` | capture `update.displayVersionString`, set `pendingUpdateVersion`, refresh menu + icon | — |
| User clicks "Check for Updates…" | (scheduled hook NOT called) `willHandleShowingUpdate` with `state.userInitiated == true` | **skip** gentle UI (user already sees the dialog) | Yes (standard) |
| User clicks "Restart to Update" | `updaterController.checkForUpdates(nil)` resumes the downloaded update | Sparkle's minimal Install & Relaunch confirmation → relaunch | Confirm only |
| User engages / session ends | `didReceiveUserAttention(forUpdate:)` / `willFinishUpdateSession()` | clear `pendingUpdateVersion`, refresh (indicator re-surfaces on next scheduled check if still uninstalled) | — |

### Update lifecycle

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Downloaded: scheduled check finds update,\nSUAutomaticallyUpdate downloads silently
    Downloaded --> Pending: shouldHandle..(immediateFocus:false) -> false\nwillHandleShowingUpdate(userInitiated:false)\nset pendingUpdateVersion -> refresh menu + icon
    Pending --> Installing: user clicks "Restart to Update"\n-> checkForUpdates(nil)
    Installing --> [*]: Install & Relaunch
    Pending --> Idle: didReceiveUserAttention / willFinishUpdateSession\n(clear; re-surfaces next check if uninstalled)
```

### Status-icon coexistence (the crux)

The existing badge is a **single** `badgeDotView` (6px, bottom-right `x: maxX-7, y: 1`), green=Keep Awake / orange=Closed Lid, mutually exclusive (`AppDelegate.swift:399-423`). The update arrow is an **independent second view** so the two states never fight:

```
Menu-bar icon (update + sleep both active):

   +---------+
   |      v  |  <- updateArrowView: arrow.down.circle.fill,
   |  [#]    |     ~9-10px, systemBlue/controlAccent, TOP-right
   |       o |  <- badgeDotView: solid dot, bottom-right
   +---------+     (green/orange) — UNCHANGED

Distinct view refs, distinct corners, distinct shape+color.
A dot = live status; an arrow = a pending action.
```

The "which indicators show" decision is a **pure function** (`statusIconIndicators(sleepMode:updatePending:)`) so the coexistence rule is unit-tested without touching AppKit.

---

## Key Technical Decisions

- **KTD-1 — Gentle reminders via `SPUStandardUserDriverDelegate` on `AppDelegate`.** AppDelegate already owns `updaterController`, the status menu, and the badge — it's the natural home. Wire `userDriverDelegate: self` in the controller init.
- **KTD-2 — Suppress only scheduled, non-focused presentations.** Return `false` from `shouldHandleShowingScheduledUpdate` only when `!inImmediateFocus`; gate gentle-UI activation on `!state.userInitiated`. This is what keeps R2 intact — user-initiated checks are never intercepted.
- **KTD-3 — `SUAutomaticallyUpdate=true`** so the bits are downloaded before the user ever sees the prompt; "Restart to Update" then just resumes. EdDSA verification still gates the actual install (R6).
- **KTD-4 — Second independent NSView for the update arrow.** Do NOT overload `badgeDotView` (it's single-state and bottom-right). A separate `updateArrowView` in the top-right is the cleanest coexistence (KTD per the chosen design).
- **KTD-5 — Reuse the sleep-items rebuild pattern for the menu.** Inject the update items via the same state-derived `refresh…` discipline (`refreshSleepStatusItems` / `menuWillOpen` / `menuDidClose`): no structural mutation of an open menu, rebuild on close, guard `menu === statusItem?.menu` (`.claude/rules/nsmenu-statusitem-gotchas.md`). The update items are static text (no live countdown), so no `.common`-mode timer is needed for them.
- **KTD-6 — "Restart to Update" calls `checkForUpdates(nil)`**, not a custom `SPUUserDriver`. A literal zero-click restart would require a custom user driver, discarding the consent/release-notes surface and adding risk on the release path — explicitly not pursued.

---

## Implementation Units

### U1. Enable silent background auto-download

**Goal:** Sparkle downloads found updates in the background so "Restart to Update" is near-instant.

**Requirements:** R5, R6

**Dependencies:** none

**Files:**
- `Sources/DrobuCore/Info.plist` (modify)

**Approach:** Add `<key>SUAutomaticallyUpdate</key><true/>`. Leave `SUEnableAutomaticChecks`, `SUFeedURL`, `SUPublicEDKey` exactly as-is. Do not touch the EdDSA key or feed URL.

**Patterns to follow:** Existing Sparkle keys block (`Info.plist:27-32`).

**Test scenarios:** Test expectation: none — pure Info.plist config, no behavioral Swift logic. Covered by manual verification (Verification section).

**Verification:** A local build with a lower version pointed at an appcast advertising a higher version downloads the update without prompting; the downloaded update is then resumable (see U3/manual verification).

---

### U2. Pure update-presentation model (+ tests)

**Goal:** Centralize the testable decisions — menu item title from a version string, and which status-icon indicators show given sleep + update state — as pure functions.

**Requirements:** R3, R4, R7, R8

**Dependencies:** none

**Files:**
- `Sources/DrobuCore/Services/UpdatePresentation.swift` (create)
- `Tests/DrobuTests/UpdatePresentationTests.swift` (create)

**Approach:** A small pure namespace/struct, no AppKit imports beyond `NSColor` mapping if convenient (prefer a plain enum for dot color so it stays test-pure):
- `updateMenuItemTitle(version: String) -> String` → `"Update available — v\(version)"` (the version string is Sparkle's `displayVersionString`, already human-readable; the helper just formats — guard against an already-`v`-prefixed string to avoid `vv`).
- `StatusIconIndicators` value type: `{ sleepDot: SleepDotColor?, showsUpdateArrow: Bool }` where `SleepDotColor` is `.green | .orange` (the existing `SleepMode` precedence: closedLid → orange, keepAwake → green, none → nil).
- `statusIconIndicators(sleepMode: SleepMode, updatePending: Bool) -> StatusIconIndicators` — the coexistence rule: the two are **independent** (arrow shows iff `updatePending`, dot shows iff a sleep mode is active).
- `statusButtonAccessibilityLabel(updatePending: Bool) -> String` → `"Drobu — update available"` when pending, else `"Drobu"`.

Keep `SleepMode` reachable by the model (it currently lives as a nested enum in AppDelegate — either lift it to this file or mirror a minimal copy; lifting is cleaner if low-churn).

**Patterns to follow:** Existing pure-logic + Swift Testing suites (`SleepCommandFormattingTests.swift`, `ActivationCopyTests.swift`).

**Test scenarios:**
- Happy: `updateMenuItemTitle(version: "1.9.1")` → `"Update available — v1.9.1"`.
- Edge: version already prefixed (`"v1.9.1"`) does not double-prefix; empty version yields a sensible fallback (decide: omit the version segment).
- Coexistence (parameterized over `SleepMode × {pending,not}`): `(none, false)` → no dot, no arrow; `(keepAwake, false)` → green dot, no arrow; `(closedLid, false)` → orange dot, no arrow; `(none, true)` → no dot, arrow; `(keepAwake, true)` → green dot **and** arrow; `(closedLid, true)` → orange dot **and** arrow.
- A11y: `statusButtonAccessibilityLabel(updatePending: true)` contains "update available"; `false` → `"Drobu"`.

**Verification:** `swift test` passes; the coexistence matrix asserts both-visible cases explicitly.

---

### U3. Gentle-reminder delegate + pending-update state

**Goal:** Suppress the modal for background checks and capture the waiting-update state; keep user-initiated checks showing the standard dialog.

**Requirements:** R1, R2, R5

**Dependencies:** U2

**Files:**
- `Sources/DrobuCore/App/AppDelegate.swift` (modify)

**Approach:**
- Init change: `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)` (`AppDelegate.swift:172-177`).
- Conform `AppDelegate` to `SPUStandardUserDriverDelegate`.
- Add state: `private var pendingUpdateVersion: String?`.
- Implement, per the behavior matrix:
  - `var supportsGentleScheduledUpdateReminders: Bool { true }`
  - `standardUserDriverShouldHandleShowingScheduledUpdate(_ update:, andInImmediateFocus immediateFocus:) -> Bool` → `return immediateFocus` (suppress when not frontmost; defer to Sparkle when the user is actively present).
  - `standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate:, forUpdate update:, state:)` → `guard !state.userInitiated else { return }`; set `pendingUpdateVersion = update.displayVersionString`; call `refreshUpdateUI()` (added in U4/U5).
  - `standardUserDriverDidReceiveUserAttention(forUpdate:)` and `standardUserDriverWillFinishUpdateSession()` → set `pendingUpdateVersion = nil`; `refreshUpdateUI()`.
- Add a `Log.info` breadcrumb on suppress / on pending-set / on clear (no user data) for field diagnosis, mirroring the existing Sparkle launch log.

**Patterns to follow:** Existing updater init + `Log.info("AppDelegate: Sparkle updater started")` (`AppDelegate.swift:171-177`); state-derived refresh dispatch like `refreshMenuBarBadge()`.

**Test scenarios:** Test expectation: none — Sparkle/AppKit delegate wiring is not unit-tested per conventions; the decision content lives in U2 and the behavior matrix. Covered by manual verification.

**Verification:** See manual verification — confirm no modal on a background check, modal preserved on user-initiated check, and that `refreshUpdateUI()` is invoked when pending flips.

---

### U4. Status-menu "Update available" + "Restart to Update" items

**Goal:** Surface the waiting update as a disabled info line + an actionable restart item at the top of the status menu.

**Requirements:** R3, R8

**Dependencies:** U2, U3

**Files:**
- `Sources/DrobuCore/App/AppDelegate.swift` (modify)

**Approach:**
- Add a state-derived rebuild for update items mirroring `refreshSleepStatusItems()` (`AppDelegate.swift:445-484`): when `pendingUpdateVersion != nil` and `!isMenuOpen`, insert at the top of the menu:
  1. a disabled `NSMenuItem(title: updateMenuItemTitle(version:), action: nil)` — no action ⇒ auto-disabled under `autoenablesItems` (the in-repo greyed-line idiom); its title is the free VoiceOver label.
  2. `NSMenuItem(title: "Restart to Update", action: #selector(restartToUpdate), keyEquivalent: "")`, `target = self`, followed by a separator.
- `@objc private func restartToUpdate()` → `updaterController?.checkForUpdates(nil)`.
- Track inserted items in a dedicated array (e.g. `updateMenuItems`) so they're removed/rebuilt independently of `sleepStatusItems`; order them ABOVE the sleep items (decide final ordering — recommend update items at the very top).
- Introduce `refreshUpdateUI()` that calls both this menu rebuild and the icon refresh (U5); call it from U3's delegate methods and from `menuWillOpen`/`menuDidClose` alongside the existing sleep refresh.
- Keep the existing "Check for Updates…" item untouched (`AppDelegate.swift:367-375`).

**Patterns to follow:** `refreshSleepStatusItems()` insert/remove + `menuWillOpen`/`menuDidClose` guards (`AppDelegate.swift:445-484, 571-599`); `.claude/rules/nsmenu-statusitem-gotchas.md` (rebuild on close, guard `menu === statusItem?.menu`, no structural mutation while open).

**Test scenarios:** Test expectation: none — NSMenu wiring is not unit-tested per conventions; title text is covered by U2. Covered by manual verification.

**Verification:** With a pending update, opening the menu shows the greyed `Update available — vX.Y.Z` and `Restart to Update`; clicking the latter resumes the install + relaunch. VoiceOver reads both items.

---

### U5. Menu-bar icon update-arrow indicator (coexists with sleep dot)

**Goal:** Add a discreet, discoverable blue down-arrow glyph in the icon's top-right when an update waits, without disturbing the bottom-right sleep dot.

**Requirements:** R4, R8

**Dependencies:** U2, U3

**Files:**
- `Sources/DrobuCore/App/AppDelegate.swift` (modify)

**Approach:**
- Add `private var updateArrowView: NSView?` — independent of `badgeDotView`.
- Add `private func refreshUpdateIcon()`: read `statusIconIndicators(sleepMode:updatePending:)` (U2). When `showsUpdateArrow`, ensure an `NSImageView` with `arrow.down.circle.fill` (`NSImage(systemSymbolName:accessibilityDescription:)`), `contentTintColor = .systemBlue` (the chosen design is a **blue** arrow — use `.systemBlue` literally, NOT `.controlAccentColor`, which follows the user's system accent and may not be blue), ~9–10px, positioned **top-right** of `statusItem.button` (e.g. `x: maxX-10, y: button.bounds.maxY-10`); else remove it. Mirror `ensureBadgeDot`'s subview-reuse shape (`AppDelegate.swift:412-423`).
- Update the button accessibility label via `statusButtonAccessibilityLabel(updatePending:)` (U2) — `setAccessibilityLabel(...)` when pending, restore `"Drobu"` when cleared.
- Have `refreshUpdateUI()` (U4) call `refreshUpdateIcon()`. The existing `refreshMenuBarBadge()` for the sleep dot is unchanged.

**Patterns to follow:** `ensureBadgeDot(in:color:)` / `updateMenuBarBadge(mode:)` (`AppDelegate.swift:399-423`); button accessibility label set in `setupStatusItem()` (`AppDelegate.swift:360`).

**Test scenarios:** Test expectation: none — NSView/NSImageView wiring is not unit-tested per conventions; the indicator-set decision and a11y label are covered by U2. Covered by manual verification.

**Verification:** Trigger a pending update → blue down-arrow appears top-right. Start Keep Awake (or Closed Lid) too → both the bottom-right sleep dot and the top-right arrow show simultaneously, no overlap. Clear the update → arrow disappears, sleep dot remains; button a11y label flips between "Drobu — update available" and "Drobu".

---

## Manual Verification (Sparkle flow)

The end-to-end update flow can't be unit-tested. Verify locally:

1. **Force an "update found":** build a local copy with a lower `CFBundleVersion`/`CFBundleShortVersionString`, OR point `SUFeedURL` at a scratch appcast advertising a higher version. To exercise the **scheduled** (not user-initiated) path, lower `SUScheduledCheckInterval` temporarily and/or clear Sparkle's last-check defaults so a background check fires soon.
2. **R1:** background check finds the update → **no modal**; the menu shows `Update available — vX.Y.Z` and the icon shows the arrow.
3. **R5/R3:** click `Restart to Update` → Sparkle's minimal Install & Relaunch confirmation (no progress bar, bits already downloaded) → app relaunches into the new version.
4. **R2:** click `Check for Updates…` → the **standard dialog still appears** (user-initiated path untouched).
5. **R4:** with a sleep mode active, confirm the arrow (top-right) and the sleep dot (bottom-right) coexist.
6. Revert any temporary `SUFeedURL` / interval / version changes before committing.

---

## Risks & Mitigations

- **User-initiated check must still show a dialog (R2).** Mitigation: `shouldHandleShowingScheduledUpdate` fires only for scheduled presentations; gentle UI is gated on `!state.userInitiated`. Verify step 4.
- **Suppressed scheduled update must be resumable.** Mitigation: documented Sparkle behavior — `checkForUpdates(nil)` resumes the downloaded update. Verify step 3.
- **Badge collision.** Mitigation: independent `updateArrowView` (top-right) vs `badgeDotView` (bottom-right); removing one never touches the other. Verify step 5.
- **Indicator cleared too eagerly on `willFinishUpdateSession`** (user dismisses without installing). Accepted: the badge clears but the still-downloaded update re-surfaces on the next scheduled check / relaunch. Documented behavior, not a defect.
- **Release path regression.** Mitigation: zero changes to `SUPublicEDKey`, `SUFeedURL`, EdDSA signing, notarization/staple. Only an additive `SUAutomaticallyUpdate` key + delegate code.
- **Background download bandwidth/battery.** Accepted: small app, EdDSA-verified install; standard Sparkle behavior.

---

## Scope Boundaries

**In scope:** gentle-reminder delegate, silent background download, status-menu update items, status-icon arrow + coexistence, accessibility labels, pure-logic tests.

### Deferred to Follow-Up Work
- A one-time `UserNotification` banner when an update is first found (the doc's `updater(_:willScheduleUpdateCheckAfterDelay:)` + `UNUserNotificationCenter` path). Intentionally omitted — a banner is closer to the "popup" being removed.
- A literal zero-click "Restart to Update" via a custom `SPUUserDriver` (loses consent/release-notes surface; higher release-path risk).

### Out of scope
- Any change to the appcast format, release pipeline, EdDSA key, or feed URL.

---

## Versioning & Rollout

Per `CLAUDE.md`, this **polishes the existing update feature** → a **PATCH** bump: `1.9.0 → 1.9.1`, `CFBundleVersion 14 → 15`. The bump can ride the next release; update all three locations in that commit: `Sources/DrobuCore/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`), `website/src/components/DownloadCTA.astro`, `website/src/components/Footer.astro`. The Settings "About" text reads the version at runtime — no edit needed.

**First-release nuance:** installed clients only get the *new* gentle behavior after they update to 1.9.1 (the delegate ships inside it). The 1.9.0 → 1.9.1 update itself is still presented by the old (modal) driver on current installs — expected; every release after 1.9.1 is gentle.
