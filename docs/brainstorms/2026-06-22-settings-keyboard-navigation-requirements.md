---
date: 2026-06-22
topic: settings-keyboard-navigation
---

# Settings Keyboard Navigation

## Summary

Make the existing Settings window keyboard-drivable so it feels like the rest of Drobu. Arrow keys and number keys move through the five sidebar sections (Set Up, Shortcuts, History, License, About) with the detail pane following instantly, and Esc closes the window. Settings stays its own `SettingsPanel` window; this brainstorm does not merge it into the main floating panel.

## Key Decisions

- **Keep Settings as a separate window.** Merging Settings into the main `FloatingPanel` was considered and dropped. The floating panel auto-closes on blur (load-bearing for the fast copy → close → paste flow), but Settings is a dwell-and-configure surface whose Set Up flow requires the window to persist while the user leaves for System Settings and returns. Keyboard navigation delivers the "feels like the app" goal without forcing a mode-aware lifecycle onto the panel.

- **Sidebar navigation only.** Keyboard control moves the section selection; the interactive controls inside each pane (hotkey recorders, Buy, retention steppers, license-key field) stay mouse-driven. Operating those by keyboard is deferred — see Scope Boundaries.

## Requirements

**Navigation**

- R1. The Settings sidebar is keyboard-navigable: ↑/↓ move the selected section through the ordered list (Set Up → Shortcuts → History → License → About), and the detail pane updates to match immediately.
- R2. Number keys 1–5 jump directly to the corresponding section (1 = Set Up, 5 = About).
- R3. Esc closes the Settings window (same dismissal path as the close button, including marking the onboarding gate complete).
- R4. ↑/↓ clamp at the first and last section — no wrap-around.

**Focus & input safety**

- R5. On opening the window the sidebar is the active keyboard target, so arrows and number keys work without a prior mouse click.
- R6. Navigation keys yield while a text field or the hotkey recorder holds first-responder focus: typing in the license-key field or recording a shortcut must not trigger section navigation.

**Accessibility**

- R7. Keyboard-driven selection preserves VoiceOver behavior — sidebar rows keep their button and selected traits, and the newly selected section is announced as it changes.

## Acceptance Examples

- AE1. Covers R5, R1. **Given** the Settings window just opened on Shortcuts, **When** the user presses ↓ with no prior click, **Then** the selection moves to History and the detail pane shows History.
- AE2. Covers R6. **Given** the License section is selected and the cursor is in the license-key text field, **When** the user types `2`, **Then** the digit is entered in the field and the section does not change to Shortcuts.
- AE3. Covers R4. **Given** About (the last section) is selected, **When** the user presses ↓, **Then** the selection stays on About.

## Scope Boundaries

Deferred for later:

- Operating the controls inside each detail pane by keyboard (record a shortcut, Buy, retention steppers, license-key entry). The Shortcuts pane's hotkey recorder captures keystrokes itself and conflicts with global key interception — a separate, larger effort with real focus-handoff edge cases.
- Merging Settings into the main `FloatingPanel`.
- A new global hotkey to open Settings — `⌘,` (status menu) and `/settings` already exist.

## Success Criteria

- A user can reach all five sections and close the window without touching the mouse.
- The new section-resolution logic (next / previous / by-index) ships with unit tests, per the project convention that new logic gets tests in the same commit.
- VoiceOver announces the selected section as it changes.

## Outstanding Questions

Deferred to Planning:

- Where the key handling attaches (SwiftUI `.onKeyPress` on the `SettingsView` root vs. an NSEvent monitor on `SettingsPanel`) and exactly how it coexists with focused in-pane controls — a codebase decision for the planning pass. R6 is the behavioral contract it must satisfy.
