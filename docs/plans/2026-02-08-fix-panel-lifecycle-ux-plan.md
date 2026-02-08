---
title: "fix: Panel Lifecycle UX Bugs"
type: fix
date: 2026-02-08
---

# Fix Panel Lifecycle UX Bugs

## Overview

Fix three connected UX bugs that break the clipboard panel after first use: stale items on reopen, broken arrow key navigation, and self-capture of pasted items. Root cause is panel reuse combined with unreliable SwiftUI lifecycle inside `NSHostingView` windows that are shown/hidden without destroying the view tree.

## Problem Statement

After the first paste cycle, the clipboard panel degrades:

1. **Stale items** — Copy new text, reopen panel, see old items. The GRDB `ValueObservation` was cancelled on `onDisappear` but never restarted because `onAppear` doesn't re-fire when `showCentered()` calls `makeKeyAndOrderFront(nil)` on an existing `NSHostingView`.

2. **Arrow key navigation breaks** — Arrow keys sometimes scroll the `ScrollView` instead of moving `selectedIndex`. The `.onKeyPress` handlers require `isSearchFocused` to be true. Since `onAppear` doesn't re-fire, `isSearchFocused` stays `false` after reopen.

3. **Self-capture** — `pasteItem()` writes to `NSPasteboard.general`, incrementing `changeCount`. The monitor's 0.5s timer detects this as a new clipboard entry and re-ingests our own paste.

## Proposed Solution

Three changes:

1. **Recreate panel on each open** — Destroy and recreate the `FloatingPanel` + SwiftUI view tree every time the hotkey fires. This guarantees `onAppear` fires, observations restart, and focus state resets. ~15ms overhead, imperceptible. Apple's Spotlight uses this pattern.

2. **Self-capture suppression flag** — Add a boolean flag to `ClipboardMonitor`. Set it before writing to pasteboard in `pasteItem()`. The monitor's next `checkForChanges()` tick sees the flag, updates `lastChangeCount`, clears the flag, and skips processing.

3. **Fix retain cycle in FloatingPanel environment** — The current `\.floatingPanel` environment key holds a strong reference to the panel, creating a cycle: `FloatingPanel` → `contentView` (NSHostingView) → SwiftUI tree → Environment → `FloatingPanel`. Replace with a weak wrapper so panels can deallocate via ARC.

## Acceptance Criteria

- [x] Opening the panel always shows the latest clipboard items, even after a paste-copy-reopen cycle
- [x] Arrow keys always navigate items (never fall through to ScrollView scrolling)
- [x] Pasting an item from the panel does not create a duplicate entry in the database
- [x] Panel opens in <50ms (no perceptible delay from recreation)
- [x] Old panels deallocate when replaced (verify with Instruments — no retain cycle)

## Changes Required

### File: `Sources/Services/ClipboardMonitor.swift`

**Add suppression flag and method.**

Add `private var isSuppressed = false` to the property list (after `database`).

**Modify `checkForChanges()` to respect the flag** — insert after `lastChangeCount = pasteboard.changeCount`:

```swift
if isSuppressed {
    isSuppressed = false
    return
}
```

`lastChangeCount` is updated before the flag check so the monitor won't re-trigger on the same changeCount after clearing suppression.

**Add public suppression method** — after `stop()`:

```swift
func suppressNextChange() {
    isSuppressed = true
}
```

Both methods run on `@MainActor` — no threading race. The flag is single-use: cleared on the very next timer tick.

### File: `Sources/App/AppDelegate.swift`

**Expose monitor** — change `private var monitor` to `private(set) var monitor`.

**Recreate panel on each open:**

```swift
private func togglePanel() {
    if let panel = panel, panel.isVisible {
        panel.close()
    } else {
        showPanel()
    }
}

private func showPanel() {
    panel?.close()  // defensive: ensure old panel is fully closed before replacement
    panel = FloatingPanel {
        ClipboardPanelView(database: self.database)
    }
    panel?.showCentered()
}
```

Removed `if panel == nil` guard — always creates fresh panel. Assigning to `panel` releases the old panel via ARC. On resignKey close (click outside), the old panel stays in memory until the next `showPanel()` replaces it — it's inert (observation cancelled, no timers) and the memory overhead is negligible. No notification plumbing needed.

### File: `Sources/Views/FloatingPanel.swift`

**Fix retain cycle in environment key.** The current code passes `self` strongly into the SwiftUI environment. Replace with a weak wrapper:

```swift
// Replace the environment key type:
struct WeakFloatingPanel {
    weak var panel: FloatingPanel?
}

private struct FloatingPanelKey: EnvironmentKey {
    static let defaultValue: WeakFloatingPanel = WeakFloatingPanel(panel: nil)
}

extension EnvironmentValues {
    var floatingPanel: WeakFloatingPanel {
        get { self[FloatingPanelKey.self] }
        set { self[FloatingPanelKey.self] = newValue }
    }
}
```

Update the init to pass the weak wrapper:

```swift
contentView = NSHostingView(rootView:
    content()
        .ignoresSafeArea()
        .environment(\.floatingPanel, WeakFloatingPanel(panel: self))
)
```

**Call `suppressNextChange()` before writing to pasteboard.** Add at the top of `pasteItem()`:

```swift
if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
    appDelegate.monitor?.suppressNextChange()
}
```

Only call this before the actual pasteboard write, not in the `default: break` branch (which only calls `clearContents()` but writes nothing useful).

**Clean up activation observer on close.** Add `deinit` or override `close()` to call `removeActivationObserver()`, preventing a stale paste if the panel is deallocated while waiting for app activation.

### File: `Sources/Views/ClipboardPanelView.swift`

**Update environment access** — change `@Environment(\.floatingPanel) private var panel` usage to go through the weak wrapper: `panel.panel?.pasteItem(...)`, `panel.panel?.close()`, `panel.panel?.consumeBufferedKeystrokes()`.

Alternatively, add a convenience computed property to keep call sites clean:

```swift
private var floatingPanel: FloatingPanel? { panel.panel }
```

## References

- Brainstorm: `docs/brainstorms/2026-02-08-fix-panel-lifecycle-ux-brainstorm.md`
- `Sources/App/AppDelegate.swift:50-65` — current panel lifecycle
- `Sources/Views/FloatingPanel.swift:41-44` — retain cycle (environment key passes `self`)
- `Sources/Views/FloatingPanel.swift:101-128` — current pasteItem flow
- `Sources/Services/ClipboardMonitor.swift:41-73` — current checkForChanges
- `Sources/Views/ClipboardPanelView.swift:66-86` — onAppear/onDisappear lifecycle (unchanged)
