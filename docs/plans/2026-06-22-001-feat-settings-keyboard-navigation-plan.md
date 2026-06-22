---
title: "feat: Settings keyboard navigation"
date: 2026-06-22
type: feat
origin: docs/brainstorms/2026-06-22-settings-keyboard-navigation-requirements.md
---

# feat: Settings keyboard navigation

## Summary

Make the existing Settings window keyboard-drivable like the rest of Drobu. Add section-navigation logic to `SettingsNavigationModel` (pure, unit-tested) and a SwiftUI key handler on `SettingsView`: ↑/↓ move between the five sidebar sections, number keys 1–5 jump directly, the detail pane follows, and Esc closes the window. The navigation keys yield while a text field or hotkey recorder holds focus. Settings stays its own `SettingsPanel` window — no merge into the main floating panel (see origin: `docs/brainstorms/2026-06-22-settings-keyboard-navigation-requirements.md`).

## Problem Frame

The Settings window is the one surface in Drobu that can't be driven from the keyboard. The clipboard panel and `/sleep` command list both navigate by arrow keys, but the Settings sidebar rows are `Text + .onTapGesture` (`SettingsView.swift:126`) with no key handling and no focus target — so reaching a section requires the mouse. Closing it the keyboard way and operating its controls don't matter for this change; the gap that breaks the "feels like the app" expectation is section navigation itself.

## Requirements

Traceability to origin requirements (`...-settings-keyboard-navigation-requirements.md`):

- R1. ↑/↓ move the selected section through the ordered list; detail follows immediately. → U1, U2
- R2. Number keys 1–5 jump directly to a section (1 = Set Up, 5 = About). → U1, U2
- R3. Esc closes the Settings window via the same dismissal path as the close button. → U2
- R4. ↑/↓ clamp at the first and last section — no wrap-around. → U1
- R5. On open, the sidebar is the active key target so keys work without a prior click. → U2
- R6. Nav keys yield while a text field or hotkey recorder holds first-responder focus. → U2
- R7. Keyboard-driven selection preserves VoiceOver traits and announces the selected section. → U2

---

## Key Technical Decisions

- **Navigation logic lives on `SettingsNavigationModel`, not in the view.** `selectNext()` / `selectPrevious()` / `select(number:)` are pure mutations of `@Published var selected`, so they're unit-testable under Swift Testing without touching SwiftUI. The view becomes a thin key-to-method mapping. This matches the project convention that new logic ships with tests, and mirrors how `landingSection` / `showsWelcomeChrome` already live as tested pure functions on the same model (`SettingsNavigationModelTests.swift`).

- **Clamp, not wrap, at the list ends (R4).** The clipboard list wraps (`(cursor + 1) % items.count`, `PanelView.swift:654`), but a five-item settings sidebar reads better with a hard stop at the ends — pressing ↓ on About stays on About. This is a deliberate divergence from the list idiom, fixed by the origin (AE3).

- **Key handler attaches to the `SettingsView` root via `.onKeyPress(phases: [.down, .repeat])`,** mirroring `PanelView.swift:261`. Match on `press.key` only — never `press.modifiers.isEmpty` — because macOS arrow keys carry `.numericPad` (see `.claude/rules/swiftui-keypress-gotchas.md`).

- **Yield-to-text-input (R6) rides the responder chain, with a focus-state backstop.** `HotkeyRecorderView` captures keys through raw `NSEvent.keyDown` and holds first responder while recording (`HotkeyRecorderView.swift:51,113`), so it already won't reach the root handler. The License-pane `TextField` (`SettingsView.swift:463`) is the real risk for digit keys. The handler must not consume a key when a text field is the active input; the exact mechanism (rely on the focused `TextField` consuming the key first, vs. gate the handler on a `@FocusState` flag tracking text-field focus) is verified during implementation — R6 and AE2 are the behavioral contract it must satisfy. See Open Questions.

---

## Implementation Units

### U1. Section-navigation logic on SettingsNavigationModel

- **Goal:** Add pure, ordered-navigation methods the key handler can call, with clamp semantics and 1-based number jumps.
- **Requirements:** R1, R2, R4
- **Dependencies:** none
- **Files:**
  - `Sources/DrobuCore/Views/SettingsNavigationModel.swift` (modify)
  - `Tests/DrobuTests/SettingsNavigationModelTests.swift` (extend)
- **Approach:** Add `selectNext()` and `selectPrevious()` that move `selected` one step through `sections` (= `SettingsSection.allCases`, stable order `setUp, shortcuts, history, license, about`) and clamp at the ends. Add `select(number: Int)` mapping 1→`setUp` … 5→`about`, treating out-of-range numbers (0, 6+) as no-ops. A private `selectedIndex` computed from `sections.firstIndex(of: selected)` keeps the three methods consistent. No view or AppKit types enter the model.
- **Patterns to follow:** The existing pure helpers and their tests on this model (`landingSection`, `showsWelcomeChrome`); enum-order assertions in `SettingsNavigationModelTests.swift`.
- **Test scenarios** (Swift Testing, `@MainActor @Suite`, sync):
  - `selectNext()` from `setUp` selects `shortcuts`; chained next from `shortcuts` selects `history`.
  - Covers AE3. `selectNext()` while on `about` (last) leaves `selected == .about`.
  - `selectPrevious()` from `setUp` (first) leaves `selected == .setUp`; from `shortcuts` selects `setUp`.
  - `select(number: 1)` selects `setUp`; `select(number: 5)` selects `about`.
  - `select(number: 0)` and `select(number: 6)` are no-ops — `selected` unchanged.
  - Order assumption guard: `sections == [.setUp, .shortcuts, .history, .license, .about]` (protects the number mapping if cases are ever reordered).
- **Verification:** `swift test` passes with the new cases; navigation methods have no SwiftUI/AppKit imports.

### U2. Keyboard handler + focus wiring in SettingsView

- **Goal:** Drive the sidebar from the keyboard — arrows, number keys, Esc-to-close — with the sidebar active on open, nav keys yielding to text input, and VoiceOver preserved.
- **Requirements:** R1, R2, R3, R5, R6, R7
- **Dependencies:** U1
- **Files:**
  - `Sources/DrobuCore/Views/SettingsView.swift` (modify)
- **Approach:** Add `.onKeyPress(phases: [.down, .repeat])` to the `SettingsView` body (the `HStack` root at `SettingsView.swift:59`), mapping `press.key`: `.upArrow` → `nav.selectPrevious()`, `.downArrow` → `nav.selectNext()`, characters `"1"`–`"5"` → `nav.select(number:)`, `.escape` → close the window via `windowProvider()?.close()` (the same path the close button uses; `SettingsPanel.close()` already stops the refresh timer and marks the onboarding gate). Return `.handled` for consumed keys, `.ignored` otherwise. Establish the sidebar as the default key target on open (R5) — e.g. a `@FocusState`-backed focusable sidebar defaulted on `.onAppear` — so arrows work with no prior click. For R6, ensure a key is `.ignored` (not consumed) when a text input is the active responder; verify against the License field per Open Questions. Confirm sidebar rows carry `.accessibilityAddTraits(.isButton)` and the selected row `.isSelected` (add if missing) so keyboard-driven selection stays VoiceOver-correct (`.claude/rules/accessibility.md`).
- **Patterns to follow:** `PanelView`'s `.onKeyPress` dispatch (`PanelView.swift:261`) and `handleClipboardKeyPress` arrow idiom (`PanelView.swift:609`, `654`); `@FocusState` usage in `PanelView.swift:50`; `.numericPad`-aware key matching from `EditableTextView.swift:21`.
- **Test scenarios:** `Test expectation: none — SwiftUI view wiring and focus/responder behavior, excluded from unit tests per project conventions.` Behavioral coverage of the navigation arithmetic is in U1; the view-level contract (AE1 open-then-↓ moves selection; AE2 typing `2` in the License field does not change section; R3 Esc closes; R7 VoiceOver) is confirmed by manual verification below.
- **Verification:** Build and launch (`pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app`); open Settings via `⌘,` or `/settings`. Confirm: ↓/↑ move sections with the detail following and no prior click (AE1); 1–5 jump to the matching section; Esc closes the window; focusing the License key field and typing `2` enters the digit without changing section (AE2); ↓ on About stays on About (AE3); VoiceOver announces each section as it's selected.

---

## Scope Boundaries

Deferred for later (carried from origin):

- Operating the controls inside each detail pane by keyboard (record a shortcut, Buy, retention steppers, license-key entry) — a separate, larger effort with hotkey-recorder focus-handoff edge cases.
- Merging Settings into the main `FloatingPanel`.
- A new global hotkey to open Settings — `⌘,` and `/settings` already exist.

---

## Open Questions

Deferred to implementation:

- The precise R6 yield mechanism: whether a focused SwiftUI `TextField` already prevents the root `.onKeyPress` from consuming digit keys, or whether the handler must explicitly gate on a `@FocusState` flag that tracks text-field focus. Resolve by testing the License field during U2; AE2 is the acceptance bar. (The hotkey recorder is already safe — it captures keys via raw `NSEvent` and never reaches `onKeyPress`.)
