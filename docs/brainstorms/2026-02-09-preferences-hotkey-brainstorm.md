# Preferences Window — Hotkey Customization

**Date:** 2026-02-09
**Status:** Ready for planning

## What We're Building

A Preferences window with a click-to-record hotkey field that lets users change the global keyboard shortcut for opening the clipboard panel. Currently hardcoded to Cmd+Shift+V.

### User Flow
1. User clicks menu bar icon → "Preferences..."
2. Settings window opens (existing SwiftUI `Settings` scene)
3. Under "General" section, the static "Global Hotkey: Cmd+Shift+V" label is replaced with an interactive click-to-record field
4. User clicks the field → it enters recording mode ("Press shortcut...")
5. User presses desired key combo (e.g., Cmd+Shift+C)
6. Field captures it, displays the new combo, persists to UserDefaults
7. Global hotkey is immediately re-registered with the new binding

### Scope
- **In scope:** Hotkey recorder UI, UserDefaults persistence, live hotkey re-registration
- **Out of scope:** Other settings (retention, limits, etc.) — deferred but design should accommodate future additions

## Why This Approach

**Custom NSView-based KeyCombo recorder** wrapped in `NSViewRepresentable` for SwiftUI.

Reasons:
- No new dependencies — works directly with existing HotKey library's `Key` enum and `NSEvent.ModifierFlags`
- HotKey's `KeyCombo` already has `dictionary` property and `init?(dictionary:)` for easy UserDefaults serialization
- Full control over recording UX (key down, modifier flags, escape to cancel)
- Battle-tested pattern — Maccy uses the same approach
- ~100 lines of custom AppKit code, minimal complexity

### Rejected Alternatives
- **KeyboardShortcuts library** — Would replace HotKey entirely (uses its own registration/persistence). Unnecessary dependency for our needs.
- **Pure SwiftUI `.onKeyPress`** — Poor modifier-key handling, can't capture raw key codes reliably for a recorder UX.

## Key Decisions

1. **Storage: UserDefaults** — Standard macOS preferences storage. Simple key-value, works with `@AppStorage`. HotKey's `KeyCombo.dictionary` provides ready-made serialization.
2. **Recorder style: Click-to-record** — User clicks field, presses desired combo. Standard macOS UX (matches Maccy, Alfred, etc.).
3. **Hotkey re-registration: Teardown/recreate** — Set `hotKey = nil` to unregister old, create new `HotKey(key:modifiers:)` to register new. Already the established pattern in the codebase (panel recreation).
4. **Extensible settings design** — Use a general-purpose settings infrastructure (UserDefaults keys, SettingsView sections) that can accommodate future settings without architectural changes.

## Open Questions

- Should we validate/warn about reserved system shortcuts (e.g., Cmd+C, Cmd+V)? Could add later if needed.
- Default shortcut on fresh install: Cmd+Shift+V (current hardcoded value, becomes the UserDefaults default).
