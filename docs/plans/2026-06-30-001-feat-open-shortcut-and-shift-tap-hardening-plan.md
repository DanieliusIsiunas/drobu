---
title: "feat: New default open shortcut (⇧⌘C) + harden large-preview Shift-tap"
date: 2026-06-30
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
plan_depth: standard
deepened: 2026-06-30
---

# feat: New default open shortcut (⇧⌘C) + harden large-preview Shift-tap

## Summary

Two coupled changes, shipped together as a patch release:

1. **Refresh the fresh-install default** for the "Paste / open" global hotkey from `⌘⇧V` to `⇧⌘C` — a deliberate **ergonomics + convention** improvement (C is closer to the Cmd/Shift cluster for one-handed reach; `⇧⌘C` is Maccy's default, so `C = Clipboard` is a learned convention). This is a preference-led default refresh, **not** a bug fix.
2. **Harden the bare-Shift-tap detector** that toggles the large preview so a Shift-containing hotkey's chord release — or a Shift+Arrow multi-select — can no longer synthesize a phantom tap. The tap-decision logic is extracted into a pure, unit-tested function.

The two are independent in code; bundling them in one patch is deliberate (both are small, both touch the same Shortcuts surface). **The detector fix is the only part that fixes the inadvertent-preview bug** — and it fixes it for *every* user (existing and fresh), since it's runtime logic, not a persisted preference. `⇧⌘C` still contains Shift, so the default swap neither causes nor cures the bug. (The "ship the detector fix alone, leave the default" alternative is viable; bundling is a deliberate choice, not an assumed one — see Scope Boundaries.)

**Product Contract preservation:** N/A — solo plan, no upstream brainstorm (`product_contract_source: ce-plan-bootstrap`).

---

## Problem Frame

The large preview window opens unexpectedly. Root cause (verified against the code): the preview is toggled by a **bare Shift tap** while the floating panel is open, detected in `FloatingPanel.swift:108-117` via a local `.flagsChanged` monitor that arms `shiftDownWithoutKey = true` whenever an event contains `.shift`, then fires `onShiftTap?()` on a later event that drops `.shift` while still armed.

When the panel is invoked via a **Shift-containing global hotkey** (the current default `⌘⇧V`, and the proposed `⇧⌘C`), `AppDelegate.showPanel()` builds a fresh `FloatingPanel` and calls `showCentered()` → `makeKeyAndOrderFront` synchronously *inside the Carbon hotkey handler*, while the physical chord is still held. The monitor is therefore installed mid-chord; Carbon swallowed the chord's letter keyDown so `shiftDownWithoutKey` is never cleared by a key; and on release the modifiers lift as separate `.flagsChanged` events in hardware-dependent order. The detector cannot tell that the trailing Shift it sees was *already held when the panel opened* — it treats the release tail as a fresh bare-Shift tap, and the preview pops.

A second, rarer path: Shift+Arrow multi-select inside the panel (`PanelView.swift:656-670`) can leave Shift held and then released with the detector armed.

Changing the default off Shift was the user's first instinct, but it's the wrong lever for the bug: `HotkeyDefaults.load()` (`HotkeyRecorderView.swift:24-30`) prefers the persisted UserDefaults combo, so a literal change reaches **fresh installs only** — and `⇧⌘C` reintroduces Shift anyway. The durable fix lives in the detector.

---

## Requirements

- **R1** — Fresh installs default the Paste/Open hotkey to `⇧⌘C` (Cmd+Shift+C). Existing users' persisted hotkey is left untouched.
- **R2** — The two capture defaults are unchanged: Capture GIF `⌃⇧G`, Capture Video `⌃⇧V`.
- **R3** — Invoking the panel via any Shift-containing hotkey (including `⇧⌘C`) must NOT open the large preview from the chord release — **regardless of how long the chord is held, or the order in which the modifiers are released**.
- **R4** — A Shift+Arrow multi-select followed by releasing Shift must NOT open the large preview.
- **R5** — A deliberate bare-Shift tap (Shift pressed and released, no other key, while the panel is open) still toggles the large preview — the gesture is preserved, not removed.
- **R6** — The Shift-tap decision is a pure function with unit tests covering every arm/fire/no-arm transition.
- **R7** — Patch version bump applied to every version surface (Info.plist display + build, website footer).

---

## Key Technical Decisions

- **KTD1 — No migration of existing users' hotkey.** The `⇧⌘C` literal affects fresh installs only; users who already bound a hotkey keep it. Changing a user's bound key out from under them is intrusive, and the detector fix (R3/R4) already protects them regardless of which combo they run. (Confirmed with user.)
- **KTD2 — Edge-aware lone-Shift arming (the core fix; replaces a rejected time-grace design).** Arm the tap only on a **rising edge to lone-Shift**: the previously-observed modifier state did NOT contain Shift, and the new state is exactly `[.shift]` (none of Cmd/Ctrl/Opt). The panel seeds its "previously-seen modifiers" from the physical modifier state captured **at show-time** (the invoking chord is still held), so the chord's Shift counts as already-down. Its release sequence — `⇧⌘`→`⇧`→`∅`, or `⇧⌘`→`⌘`→`∅` — therefore never produces a Shift *rising edge*, so it never arms. A *deliberate* tap presses Shift up from a no-Shift state → a genuine rising edge → arms. This defeats the chord-release tail **independent of hold duration and release order** — the two properties the original design could not guarantee.
  - *Rejected alternative (caught in review):* a lone-modifier gate plus a ~250ms grace window timed from panel-show. The grace clock starts while the chord is still physically held, so any hold longer than the window re-opens the exact R3 bug; widening the constant trades directly against R5, and the design also rested on unmeasured hold-duration and a hardware-dependent release order. Edge detection has none of these dependencies.
- **KTD3 — No clock in the detector.** Because arming is edge-based, the detector needs neither a `Timer` nor a `Date()` comparison. The only new state is the previously-seen masked modifier set, seeded at show-time from `NSEvent.modifierFlags` and updated on each event. This keeps the pure function free of time and AppKit; the `.common`-mode timer rule in `nsmenu-statusitem-gotchas.md` does not apply because there is no timer.
- **KTD4 — Keep the existing `keyDown` → disarm path unchanged.** The local `keyDown` monitor (`FloatingPanel.swift:59-62`) clears the armed flag on any key, including arrow keys (the monitor sees events before SwiftUI's `onKeyPress` consumes them — see the comment at `FloatingPanel.swift:51-54`, verified). This is the sole guard for the multi-select case (R4): after a rising-edge arm from Shift, the first arrow keyDown disarms, so the later Shift release never fires. The edge rule (KTD2) and the keyDown disarm (KTD4) own **distinct** cases — the chord-release tail and multi-select respectively — with no overlap, so both are load-bearing.
- **KTD5 — `⇧⌘C` accepted despite the browser-DevTools overlap.** `⇧⌘C` toggles inspect-element in Chrome/Edge/Firefox DevTools (a global hotkey shadows it). Examined for Drobu's developer-heavy, paying buyer — not merely inherited from Maccy: the hotkey is rebindable in-app, surfaced in first-run onboarding and Settings → Shortcuts, and `⇧⌘C` is the category convention (Maccy's default). Judged an acceptable default-time tradeoff, and cheap to reverse (a one-token literal reachable only by fresh installs). No system-wide function of the "Copy as Pathname / Copy Style" severity is shadowed (that was `⌥⌘C`, rejected earlier).

---

## Scope Boundaries

**In scope:** the default-literal swap (Paste/Open only), the detector hardening + pure-function extraction + tests, and the version bump.

### Deferred to Follow-Up Work
- One-time UserDefaults migration of the old `⌘⇧V` default → `⇧⌘C` for existing users (explicitly declined per KTD1).
- **Shipping the detector fix alone, with no default change** — the minimal bug-fix release. Viable (the detector fix is what cures the bug); bundling the default refresh is the deliberate choice here, recorded so the coupling is intentional, not assumed.
- Replacing the bare-Shift-tap *gesture* with a discrete key (e.g. Space / Cmd-Y). The gesture is kept and hardened, not swapped.

---

## Implementation Units

### U1. Flip the Paste/Open default literal to ⇧⌘C

**Goal:** Fresh installs open the panel with `⇧⌘C` instead of `⌘⇧V`.

**Requirements:** R1, R2.

**Dependencies:** none.

**Files:**
- `Sources/DrobuCore/Views/HotkeyRecorderView.swift` (modify — `HotkeyDefaults.load()` fallback at line 27)

**Approach:** Change the fallback `KeyCombo(key: .v, modifiers: [.command, .shift])` to `KeyCombo(key: .c, modifiers: [.command, .shift])`. Touch **only** `HotkeyDefaults`; leave `CaptureHotkeyDefaults` (`.g`/`[.control,.shift]`) and `VideoCaptureHotkeyDefaults` (`.v`/`[.control,.shift]`) untouched (R2). The persisted-combo branch above the fallback is unchanged, so existing users are unaffected (R1, KTD1).

**Patterns to follow:** the sibling fallbacks in `CaptureHotkeyDefaults.swift:24` / `:45` — same `KeyCombo(key:modifiers:)` shape.

**Test scenarios:** `Test expectation: none` — trivial one-token default literal with no branching logic; CLAUDE.md "Testing" explicitly excludes trivial default values. Covered by the build + manual launch in U3's verification (fresh-defaults check) and the Definition of Done.

**Verification:** with no `globalHotkey` key in UserDefaults, a fresh launch registers `⇧⌘C` and the Settings → Shortcuts "Paste / open" row reads `⇧⌘C`.

---

### U2. Extract the pure edge-aware Shift-tap decision function + unit tests

**Goal:** Move the arm/fire logic out of the AppKit monitor into a pure, testable function implementing KTD2's rising-edge rule.

**Requirements:** R3, R4, R5, R6.

**Dependencies:** none.

**Files:**
- `Sources/DrobuCore/Views/ShiftTapDetector.swift` (create — the pure function + doc comment)
- `Tests/DrobuTests/ShiftTapDetectorTests.swift` (create)

**Approach:** Add a top-level `internal` free function (reachable from tests via `@testable import DrobuCore`, mirroring `screenRecordingGrantedFromWindows`). It takes the **already-masked** previous and current relevant-modifier sets and the current armed state; it returns the next armed state plus whether to fire the tap. Suggested shape (directional, not a signature mandate):

```
func shiftTapDecision(previous: NSEvent.ModifierFlags,   // both pre-masked to [.shift,.command,.control,.option]
                      current: NSEvent.ModifierFlags,
                      armed: Bool) -> (armed: Bool, fireTap: Bool)
```

Decision table (directional guidance):

| `current` (masked)            | rising edge? (`current == [.shift] && !previous.contains(.shift)`) | `armed` in | → `armed` out | `fireTap` |
|-------------------------------|--------------------------------------------------------------------|-----------|---------------|-----------|
| `[.shift]`, prev had no Shift | yes                                                                | any       | `true`        | `false`   |
| `[.shift]`, prev already Shift| no                                                                 | any       | unchanged     | `false`   |
| `[]` (all released)           | —                                                                  | `true`    | `false`       | **`true`** |
| `[]` (all released)           | —                                                                  | `false`   | `false`       | `false`   |
| contains a non-Shift modifier | —                                                                  | any       | `false`       | `false`   |

The "non-rising lone-Shift preserves `armed`" row matters: a deliberate tap arms on the rising edge, and a redundant `[.shift]` event before release must not silently drop that arm (which would violate R5). Masking to the four relevant flags happens in the caller (U3), so Caps-Lock / Fn / numericPad noise never reaches this function. There is no time input — arming is purely edge-based (KTD3).

**Patterns to follow:** `screenRecordingGrantedFromWindows` in `Sources/DrobuCore/Services/PermissionsService.swift:66` (top-level pure func + value inputs + doc comment) and its tests in `Tests/DrobuTests/PermissionsServiceTests.swift` (Swift Testing `@Suite`/`@Test`/`#expect`).

**Test scenarios** (cover every decision-table row + both release orders):
- *Happy path — gesture preserved:* `previous: [.shift]`, `current: []`, `armed: true` → `(false, fireTap: true)` (R5).
- *Rising-edge lone-Shift arms:* `previous: []`, `current: [.shift]`, `armed: false` → `(true, false)`.
- *Chord-release tail, Cmd lifts first, never arms:* `previous: [.shift, .command]`, `current: [.shift]`, `armed: false` → `(false, false)` — the headline R3 case (not a rising edge because Shift was already down).
- *Chord-release tail, then full release, no fire:* `previous: [.shift]`, `current: []`, `armed: false` → `(false, false)` (R3).
- *Chord-release tail, Shift lifts first, never arms:* `previous: [.shift, .command]`, `current: [.command]`, `armed: false` → `(false, false)` (R3 — release-order independence).
- *Simultaneous chord rising edge never arms:* `previous: []`, `current: [.shift, .command]`, `armed: false` → `(false, false)`.
- *Post-multi-select release with armed already cleared by keyDown:* `previous: [.shift]`, `current: []`, `armed: false` → `(false, false)` (R4).
- *Redundant non-rising lone-Shift preserves an arm:* `previous: [.shift]`, `current: [.shift]`, `armed: true` → `(true, false)` (guards R5 against duplicate events).

**Verification:** `swift test` — the new suite passes; every decision-table row and both release orders are asserted.

---

### U3. Wire the pure function into FloatingPanel + seed the show-time modifier baseline

**Goal:** Replace the inline `handleFlagsChanged` logic with masked previous/current → `shiftTapDecision`, seeded so the held invoking chord is treated as already-down.

**Requirements:** R3, R4, R5.

**Dependencies:** U2.

**Files:**
- `Sources/DrobuCore/Views/FloatingPanel.swift` (modify — `handleFlagsChanged` 108-117; add a `lastRelevantFlags` property; seed it in `showCentered()` near `makeKeyAndOrderFront(nil)` at line 150)

**Approach:**
- Add `private var lastRelevantFlags: NSEvent.ModifierFlags = []`. In `showCentered()`, seed it from the live modifier state captured at show-time: `lastRelevantFlags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])`, set immediately before/after `makeKeyAndOrderFront(nil)` (line 150). Because the panel is recreated each show, the seed is fresh per invocation.
- In `handleFlagsChanged`, mask the event flags (`event.modifierFlags.intersection([.shift, .command, .control, .option])`), call `shiftTapDecision(previous: lastRelevantFlags, current: masked, armed: shiftDownWithoutKey)`, assign the returned `armed` to `shiftDownWithoutKey`, fire `onShiftTap?()` only when `fireTap` is true, then update `lastRelevantFlags = masked`.
- The single intersection over the four named flags is intentionally sufficient — no `.deviceIndependentFlagsMask` hop is needed (the named-flag intersection already discards device-dependent bits), so this does not contradict the `.deviceIndependentFlagsMask`-first idiom in `HotkeyRecorderView.swift:140-141`.
- Leave the `keyDown` monitor / `keyDown` override disarm paths (`FloatingPanel.swift:59-62`, `98-104`) unchanged (KTD4).

**Patterns to follow:** the existing impure-wrapper / pure-core split in `SystemPermissionProbe` ↔ `screenRecordingGrantedFromWindows` (`PermissionsService.swift`) — AppKit/syscall in the wrapper, decision in the pure function.

**Test scenarios:** `Test expectation: none` — AppKit `NSPanel` event-monitor wiring is not unit-tested per CLAUDE.md ("What NOT to test: NSPanel lifecycle, AppKit UI wiring"). The decision logic is covered by U2; this unit is covered by the manual verification below, which **must exercise the discriminating variable (hold duration)** since the unit tests feed `previous`/`current`/`armed` directly and cannot prove the caller seeds and updates them correctly.

**Verification (manual, build + launch via `pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app`):**
1. Invoke with `⇧⌘C` and **release quickly** → preview does not auto-open (R3, fast path).
2. Invoke with `⇧⌘C` and **hold ~1 second before releasing** → preview does not auto-open (R3, slow-hold path — the case the rejected time-grace design failed).
3. Invoke with the prior `⌘⇧V` (set it manually in Settings), both quick and held → also does not auto-open (R3 holds for any Shift combo, protecting existing users).
4. Open the panel, Shift+Down/Up to multi-select several rows, release Shift → preview does **not** open (R4).
5. Open the panel, then tap and release Shift with no other key → preview **toggles** open; tap again → closes (R5).

---

### U4. Patch version bump

**Goal:** Ship the change as a release.

**Requirements:** R7.

**Dependencies:** U1, U2, U3.

**Files:**
- `Sources/DrobuCore/Info.plist` (modify — `CFBundleShortVersionString` `1.9.6` → `1.9.7`; `CFBundleVersion` `20` → `21`)
- `website/src/components/Footer.astro` (modify — `v1.9.6` → `v1.9.7`, line 14)

**Approach:** Patch tier per CLAUDE.md versioning (refines/fixes existing behavior — no distinctly new capability). `CFBundleVersion` increments by exactly one. The Settings "About" text reads `CFBundleShortVersionString` at runtime, so no edit there.

**Patterns to follow:** the CLAUDE.md "Versioning" 2-place checklist.

**Test scenarios:** `Test expectation: none` — version strings, no logic.

**Verification:** `plutil -extract CFBundleShortVersionString raw Sources/DrobuCore/Info.plist` → `1.9.7`; footer renders `v1.9.7`.

---

## Risks & Dependencies

- **`⇧⌘C` shadows browser DevTools inspect-element globally** (KTD5). Accepted (rebindable; surfaced in onboarding/Settings; category convention). Documented, not mitigated.
- **Edge-aware arming depends on the panel being recreated each show** so `lastRelevantFlags` is re-seeded from the live chord state. This holds today (`AppDelegate.showPanel` builds a new `FloatingPanel`, and the seed lives in `showCentered()`). If panel reuse is ever introduced, the seed must still run on each show.
- **R4 relies on the `keyDown` monitor firing for the arrow keyDown before SwiftUI consumes it** (`FloatingPanel.swift:59-62`, documented at `:51-54`, verified to hold today). This is an AppKit event-routing assumption (local monitor precedes responder-chain delivery) that a future SwiftUI/AppKit change could perturb; the manual verification step 4 guards it per release.
- **Sequencing:** U3 depends on U2 (needs the pure function). U1 and U4 are independent; U4 ships last.

---

## System-Wide Impact

- **Existing users:** unaffected by the default swap (keep their saved hotkey, R1/KTD1); **do** benefit from the detector fix (runtime logic, applies on next launch regardless of bound combo). This is the change's real value for the install base.
- **Fresh installs:** get `⇧⌘C` for Paste/Open; captures unchanged.
- No DB, no schema, no daemon, no licensing surface touched. No appcast/Sparkle implications beyond a normal patch release.

---

## Definition of Done

- `HotkeyDefaults.load()` fallback is `⇧⌘C`; capture fallbacks unchanged (R1, R2).
- `ShiftTapDetector` pure function exists with the full decision-table test suite (every row + both release orders) green under `swift test` (R6); the existing ~73-test suite still passes.
- `FloatingPanel` routes flags through the masked previous/current → `shiftTapDecision` path with the show-time `lastRelevantFlags` seed (R3, R5); the `keyDown` disarm path is intact (R4); no `Timer`/`Date()` added to the detector (KTD3).
- All five U3 manual-verification steps pass on an installed build — **including the ~1-second hold (step 2)**, which is the case that discriminates the edge-aware fix from the rejected time-grace design.
- Version reads `1.9.7` / build `21` in Info.plist and `v1.9.7` in the footer (R7).

---

## Sources & Research

- Code mechanism + root cause: verified live this session against `FloatingPanel.swift:55-117` & `:126-151`, `PanelView.swift:207-215` & `656-670`, `AppDelegate.swift` showPanel/Carbon registrations, `HotkeyRecorderView.swift:24-30` & `:140-141`, `CaptureHotkeyDefaults.swift`.
- Edge-aware redesign: adopted after a four-lens document review (coherence, feasibility, product-lens, adversarial) in which feasibility and adversarial independently found that a grace window anchored to panel-show time fails for chord holds longer than the window — the show-time seed + rising-edge rule removes the hold-duration and release-order dependencies.
- Conflict + ergonomics + convention analysis (why `⇧⌘C` over `⌥⌘C`, Maccy precedent, DevTools overlap): the earlier four-lens hotkey evaluation workflow this session.
- Pure-function + test pattern to mirror: `PermissionsService.swift:66` / `PermissionsServiceTests.swift`.
- Conventions: `CLAUDE.md` (Testing, Versioning), `.claude/rules/swiftui-macos-gotchas.md`, `.claude/rules/swiftui-keypress-gotchas.md` (arrow-key `.numericPad` modifier — relevant when masking), `.claude/rules/nsmenu-statusitem-gotchas.md`.
