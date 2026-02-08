# Fix Panel Lifecycle UX Bugs

**Date:** 2026-02-08
**Status:** Ready for planning

## What We're Building

Fix three connected UX bugs that break the clipboard panel after first use:

1. **Stale items** — After pasting an item and copying new text, reopening the panel shows old items instead of the fresh copy.
2. **Arrow key navigation breaks** — Sometimes arrow keys navigate items (correct), sometimes they scroll the ScrollView (incorrect).
3. **Self-capture** — When the app pastes an item, it writes to `NSPasteboard.general`, which the monitor detects and re-records as a "new" clipboard entry.

## Why These Happen

### Root cause: Panel reuse + unreliable SwiftUI lifecycle

The panel is created once in `AppDelegate.showPanel()` and reused:

```swift
private func showPanel() {
    if panel == nil {
        panel = FloatingPanel { ClipboardPanelView(database: self.database) }
    }
    panel?.showCentered()
}
```

When the panel closes, `onDisappear` cancels the GRDB `ValueObservation`. When it reopens via `showCentered()` (just `makeKeyAndOrderFront`), `onAppear` does NOT reliably re-fire for SwiftUI views inside `NSHostingView` windows that are shown/hidden without destroying the view tree. So:

- Observation stays dead → items never refresh (Bug 1)
- `isSearchFocused` isn't re-set → `.onKeyPress` handlers don't receive events → arrow keys fall through to ScrollView native scrolling (Bug 2)

### Self-capture (Bug 3)

`pasteItem()` writes the selected record to `NSPasteboard.general` before firing synthetic Cmd+V. The monitor's 0.5s timer detects this as a new clipboard change and re-ingests our own paste.

## Why This Approach

**Recreate the panel each time it opens.**

- SwiftUI lifecycle (`onAppear`/`onDisappear`) fires reliably because it's a fresh view tree
- No stale state, no focus issues, no observation lifecycle bugs
- The panel is lightweight (~15ms creation overhead, imperceptible)
- Apple's own Spotlight does exactly this pattern
- Simplest solution — no manual lifecycle hooks, no state coordination

**Self-capture prevention** via a flag on ClipboardMonitor that suppresses the next changeCount check when we know we just wrote to the pasteboard.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Panel lifecycle | Recreate on each show | Simplest, most reliable. Avoids fighting SwiftUI lifecycle in NSHostingView. |
| Self-capture fix | Suppression flag in ClipboardMonitor | Lightweight. Set flag before writing to pasteboard, clear after monitor's next tick. |
| Panel close | Set `panel = nil` in AppDelegate | Ensures the old panel + SwiftUI tree is deallocated, fresh one created next open. |
| Focus strategy | Trust `onAppear` + `isSearchFocused` | Works correctly when `onAppear` actually fires (which it will with fresh panel). |

## Changes Required

### File: `AppDelegate.swift`

- `togglePanel()`: On close, set `panel = nil`
- `showPanel()`: Always creates a new `FloatingPanel` (remove the `if panel == nil` guard)

### File: `FloatingPanel.swift`

- `close()` override or `resignKey()`: Notify AppDelegate to nil out the panel reference
- OR: Simply let `AppDelegate.togglePanel()` handle cleanup

### File: `ClipboardMonitor.swift`

- Add `var isSuppressed: Bool` flag
- In `checkForChanges()`: if suppressed, update `lastChangeCount` but skip processing, then clear flag
- Expose a `suppressNextChange()` method

### File: `FloatingPanel.swift` (paste flow)

- Before writing to pasteboard in `pasteItem()`, call `monitor.suppressNextChange()`
- This requires passing the monitor reference or using a notification

## Open Questions

None — approach is clear and minimal.

## Next Step

Run `/workflows:plan` to create implementation plan with exact code changes.
