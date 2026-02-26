---
title: Slash Commands System with /sleep (Caffeinate)
type: feat
date: 2026-02-26
---

# Slash Commands System with /sleep (Caffeinate)

## Overview

Add a slash command system to ClipboardHistory that transforms the search bar into a command palette when the user types `/`. The first command is `/sleep` — macOS sleep prevention via `caffeinate`. This establishes the architectural pattern for future commands while keeping the implementation focused on what `/sleep` needs.

## Problem Statement / Motivation

ClipboardHistory is a keyboard-driven utility that the user opens frequently via a global hotkey. It's the ideal surface for quick system actions that don't warrant a separate app or terminal command. Sleep prevention (`caffeinate`) is a common need during presentations, long downloads, or development sessions — but currently requires opening Terminal and running a command manually.

## Proposed Solution

### Architecture

```
┌─────────────────────────────────────────────────┐
│ AppDelegate                                     │
│  ├── CaffeinateService (singleton, owns Process)│
│  ├── ClipboardMonitor (existing)                │
│  └── FloatingPanel                              │
│       └── PanelView (renamed from              │
│            ClipboardPanelView)                   │
│            ├── .clipboard mode (existing)        │
│            ├── .commandList mode (new)           │
│            └── .commandOptions mode (new)        │
└─────────────────────────────────────────────────┘
```

**Three-layer approach:**

1. **CaffeinateService** — Singleton on AppDelegate. Owns the `Process` reference, tracks start time + duration, notifies via `onStateChange` callback (matching `ScreenCaptureService` pattern). Survives panel recreation.

2. **SlashCommand protocol** — Lightweight interface: `name`, `icon`, `description`, `options(context:)`, `execute(option:)`. One conforming type: `SleepCommand`.

3. **PanelView mode switching** — Enum-driven mode (`.clipboard`, `.commandList`, `.commandOptions`) that controls what the list area shows and how keyboard events are routed.

### State Machine

```
                    type "/"                    select command
  ┌──────────┐  ─────────────►  ┌──────────────┐  ──────────►  ┌────────────────┐
  │ clipboard │                 │ commandList  │              │ commandOptions │
  │   mode    │  ◄─────────────  │    mode      │  ◄──────────  │     mode       │
  └──────────┘    Esc (clear     └──────────────┘    Esc        └────────────────┘
       │          searchText)          │                              │
       │                               │                              │
       ▼                               ▼                              ▼
   Esc: close                      Esc: clear "/"               Esc: back to
    panel                          → clipboard mode             commandList mode
```

### Escape Cascade (3 levels)

1. **commandOptions** → Escape → back to **commandList** (searchText = "/")
2. **commandList** → Escape → clear searchText → **clipboard** mode
3. **clipboard** → Escape → close panel (existing behavior)

## Technical Approach

### Phase 1: CaffeinateService (Foundation Layer)

Create the service that manages the `caffeinate` subprocess, independent of any UI.

**New file:** `Sources/Services/CaffeinateService.swift`

```swift
// Sources/Services/CaffeinateService.swift
import Foundation

@MainActor
final class CaffeinateService {
    enum State: Equatable {
        case idle
        case active(startDate: Date, duration: TimeInterval)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Callback for state changes — set by AppDelegate to update menu bar badge.
    /// Matches the existing ScreenCaptureService.onStateChange pattern.
    var onStateChange: ((State) -> Void)?

    private var process: Process?

    var remainingTime: TimeInterval? { /* compute from state */ }
    var isActive: Bool { /* check state != .idle */ }

    func start(duration: TimeInterval) { /* kill existing, launch new */ }
    func stop() { /* terminate process, set idle */ }

    // Called by AppDelegate on quit
    func cleanup() { /* terminate if running */ }
}
```

**Key behaviors:**
- `start(duration:)` kills any existing process first, then launches `caffeinate -dims -t <seconds>`
- Uses **callback pattern** (`onStateChange`) for state notifications, matching the existing `ScreenCaptureService` pattern — no Combine dependency
- `remainingTime` computed from `startDate + duration - Date.now`
- `cleanup()` called from `applicationWillTerminate` — kills caffeinate on app quit
- `onStateChange` callback drives both the menu bar badge and panel UI

**Critical: `terminationHandler` threading.** `Process.terminationHandler` fires on an arbitrary background thread. Must dispatch back to `@MainActor` explicitly:

```swift
process.terminationHandler = { [weak self] _ in
    Task { @MainActor in
        self?.state = .idle
        self?.process = nil
    }
}
```

Do NOT call `waitUntilExit()` — that blocks the main thread. Use fire-and-forget with `terminationHandler`.

**Error handling:** `Process.run()` throws. Catch the error, log it, keep state as `.idle`. Do not show an `NSAlert` — graceful silent failure is appropriate for a utility app.

**Integration with AppDelegate:**

```swift
// Sources/App/AppDelegate.swift
// Add as property alongside existing services
private let caffeinateService = CaffeinateService()

// In applicationWillTerminate or quit handler:
caffeinateService.cleanup()
```

**Files to create:**
- `Sources/Services/CaffeinateService.swift`

**Files to modify:**
- `Sources/App/AppDelegate.swift` — add `caffeinateService` property, set `onStateChange` callback for badge, pass to panel, call `cleanup()` on quit

---

### Phase 2: SlashCommand Protocol + SleepCommand

Define the lightweight protocol and the first command implementation.

**New file:** `Sources/Models/SlashCommand.swift`

```swift
// Sources/Models/SlashCommand.swift

struct CommandOption: Identifiable {
    let id: String
    let label: String
    let icon: String?        // SF Symbol name
    let isDestructive: Bool  // e.g., "Cancel" in red
}

protocol SlashCommand {
    var name: String { get }           // "sleep"
    var displayName: String { get }    // "Sleep Prevention"
    var icon: String { get }           // SF Symbol: "moon.zzz"
    var description: String { get }    // "Prevent your Mac from sleeping"

    func options() -> [CommandOption]
    func execute(option: CommandOption)
}
```

**New file:** `Sources/Services/SleepCommand.swift`

```swift
// Sources/Services/SleepCommand.swift

final class SleepCommand: SlashCommand {
    let name = "sleep"
    let displayName = "Sleep Prevention"
    let icon = "moon.zzz"
    let description = "Prevent your Mac from sleeping"

    private let service: CaffeinateService

    func options() -> [CommandOption] {
        var opts: [CommandOption] = []

        if service.isActive, let remaining = service.remainingTime {
            // Status row (non-actionable, just informational)
            // Cancel option
            opts.append(CommandOption(id: "cancel", label: "Stop Sleep Prevention", icon: "stop.circle", isDestructive: true))
        }

        // Duration options (always shown)
        opts.append(contentsOf: [
            CommandOption(id: "15m",  label: "15 minutes", icon: "clock", isDestructive: false),
            CommandOption(id: "30m",  label: "30 minutes", icon: "clock", isDestructive: false),
            CommandOption(id: "1h",   label: "1 hour",     icon: "clock", isDestructive: false),
            CommandOption(id: "2h",   label: "2 hours",    icon: "clock", isDestructive: false),
            CommandOption(id: "4h",   label: "4 hours",    icon: "clock", isDestructive: false),
        ])

        return opts
    }

    func execute(option: CommandOption) {
        switch option.id {
        case "cancel": service.stop()
        case "15m":    service.start(duration: 15 * 60)
        case "30m":    service.start(duration: 30 * 60)
        case "1h":     service.start(duration: 60 * 60)
        case "2h":     service.start(duration: 2 * 60 * 60)
        case "4h":     service.start(duration: 4 * 60 * 60)
        default: break
        }
    }
}
```

**Selecting a new duration while already active:** Kills the current process, starts a new one (simplest, most intuitive).

**Files to create:**
- `Sources/Models/SlashCommand.swift`
- `Sources/Services/SleepCommand.swift` (alongside `CaffeinateService.swift`, not a new directory)

---

### Phase 3: PanelView Mode Switching

Rename `ClipboardPanelView` → `PanelView` and add mode-driven rendering.

**Rename:** `Sources/Views/ClipboardPanelView.swift` → `Sources/Views/PanelView.swift`

**New state:**

```swift
enum PanelMode {
    case clipboard
    case commandList
    case commandOptions(command: any SlashCommand)
}

@State private var panelMode: PanelMode = .clipboard
@State private var commandItems: [CommandOption] = []  // options for selected command
```

**Search text interception** (in existing `onChange(of: searchText)`):

```swift
.onChange(of: searchText) { _, newValue in
    if newValue.hasPrefix("/") {
        if case .commandOptions = panelMode {
            // Don't change mode while in options
        } else {
            panelMode = .commandList
            // Filter commands by query (text after "/")
        }
    } else {
        panelMode = .clipboard
        startObservation()  // Resume GRDB observation
    }
}
```

**GRDB observation lifecycle:**
- **Entering command mode:** Cancel the GRDB `ValueObservation` to prevent phantom updates
- **Returning to clipboard mode:** Restart observation via `startObservation()`
- This prevents clipboard DB changes from corrupting selection state during command browsing

**Search bar placeholder:**
- `.clipboard` mode: "Search..." (existing)
- `.commandList` / `.commandOptions` mode: "Type a command..."

**List rendering (left panel):**

```swift
@ViewBuilder
private var listContent: some View {
    switch panelMode {
    case .clipboard:
        // Existing ForEach over clipboard items with ClipboardRowView
    case .commandList:
        ForEach(filteredCommands, id: \.name) { command in
            CommandRowView(command: command, isCursor: /* ... */)
        }
    case .commandOptions(let command):
        ForEach(command.options(), id: \.id) { option in
            CommandOptionRowView(option: option, isCursor: /* ... */)
        }
    }
}
```

**Keyboard handler modifications:**

| Key | `.clipboard` | `.commandList` | `.commandOptions` |
|-----|-------------|----------------|-------------------|
| Up/Down | Navigate clipboard items | Navigate commands | Navigate options |
| Return | Paste selected | Enter `.commandOptions` | Execute option, close panel |
| Escape | Clear selection → clear search → close | Clear search → `.clipboard` | Back to `.commandList` |
| Backspace | Normal text editing | Normal text editing (delete chars after "/") | **Act as Escape** — back to `.commandList` |
| Right Arrow | Enter edit mode | No-op | No-op |
| Shift+Arrow | Multi-select | No-op | No-op |
| Delete | Delete clipboard item | No-op | No-op |
| Cmd+1-9 | Quick paste | No-op | No-op |

**Backspace behavior in `.commandOptions`:** The search bar is frozen (showing "/sleep"). Pressing Backspace acts as Escape — returns to `.commandList` mode with `searchText = "/"`. This matches the user's mental model of "go back" without requiring them to reach for Escape.

**Entering `.commandOptions` from `.commandList`:**
- When user presses Return on a command in the list
- Set `panelMode = .commandOptions(command: selectedCommand)`
- Search bar shows "/sleep" (frozen — typing and backspace are intercepted, not forwarded to text field)
- Reset cursor to 0

**Files to modify:**
- `Sources/Views/ClipboardPanelView.swift` → rename to `Sources/Views/PanelView.swift`, add mode enum, branch rendering + keyboard handlers
- `Sources/App/AppDelegate.swift` — update `showPanel()` to use `PanelView`, pass `caffeinateService`
- `Sources/Views/FloatingPanel.swift` — update any references to `ClipboardPanelView`

**New files:**
- `Sources/Views/CommandRowView.swift` — row for command list (icon + name + description, 32px height)
- `Sources/Views/CommandOptionRowView.swift` — row for command options (icon + label, 32px height)

---

### Phase 4: Preview Panel in Command Mode

Modify the preview panel to show minimal status when caffeinate is active.

**File:** `Sources/Views/PreviewPanel.swift`

**Behavior by mode:**
- `.clipboard` — existing preview (text, image, GIF)
- `.commandList` — empty (or brief description of highlighted command)
- `.commandOptions` where caffeinate is active — live countdown display:

```swift
// Countdown view
VStack(spacing: 8) {
    Image(systemName: "moon.zzz")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
    Text("Sleep Prevention Active")
        .font(.headline)
    Text(remainingTimeFormatted)  // "1:23:45"
        .font(.system(size: 28, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
}
```

**Timer:** Use `TimelineView(.periodic(from: .now, by: 1))` for countdown updates — no manual Timer needed, SwiftUI handles lifecycle.

**Files to modify:**
- `Sources/Views/PreviewPanel.swift` — add command mode branches

---

### Phase 5: Menu Bar Badge

Add a small green dot to the menu bar icon when caffeinate is active.

**Approach:** Composite a green circle onto the existing `NSImage` when active, restore original when idle.

```swift
// In AppDelegate, set up callback (matching ScreenCaptureService pattern)
caffeinateService.onStateChange = { [weak self] state in
    self?.updateMenuBarBadge(isActive: state != .idle)
}

private var badgeDotView: NSView?

private func updateMenuBarBadge(isActive: Bool) {
    guard let button = statusItem?.button else { return }
    if isActive {
        if badgeDotView == nil {
            let dot = NSView(frame: NSRect(x: button.bounds.maxX - 7, y: 1, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3
            button.addSubview(dot)
            badgeDotView = dot
        }
    } else {
        badgeDotView?.removeFromSuperview()
        badgeDotView = nil
    }
}
```

**Badge approach: Separate NSView overlay** (not image compositing).

Why NOT composite onto the NSImage:
- `NSImage.lockFocus` / `unlockFocus` is deprecated since macOS 10.14
- `NSImage(size:flipped:drawingHandler:)` would work, but setting `isTemplate = false` on the composite image makes the entire icon lose dark mode adaptation (the base icon would no longer auto-tint for light/dark)
- A separate `NSView` subview preserves the template icon behavior while adding a colored dot on top

**Badge specs:**
- Size: 6x6pt circle (12x12px @2x)
- Color: `NSColor.systemGreen` via layer background
- Position: bottom-right corner of the status bar button
- Rendering: `NSView` subview with `cornerRadius = 3` — keeps its green color regardless of system appearance

**Files to modify:**
- `Sources/App/AppDelegate.swift` — set `onStateChange` callback, add `updateMenuBarBadge()` method with `NSView` overlay

---

## Acceptance Criteria

### Functional Requirements

- [x] Typing `/` in the search bar switches panel to command mode showing all commands
- [x] `/sleep` appears as a command with moon icon and description
- [x] Typing `/sle` filters the command list to show only matching commands
- [x] Arrow keys navigate commands and options; Return selects
- [x] Selecting a duration starts `caffeinate -dims -t <seconds>` as background process
- [x] Panel closes after selecting a duration
- [x] Menu bar icon shows green dot badge while caffeinate is active
- [x] Re-entering `/sleep` while active shows remaining time + cancel + duration options
- [x] Selecting "Cancel" terminates the caffeinate process
- [x] Selecting a new duration while active replaces the current session
- [x] Escape in command options → back to command list
- [x] Escape in command list → clear search → back to clipboard mode
- [x] Escape in clipboard mode → close panel (existing behavior)
- [x] Caffeinate process is killed when the app quits
- [x] Green dot badge is removed when caffeinate expires or is cancelled
- [x] Search bar placeholder changes to "Type a command..." in command modes
- [x] GRDB observation is cancelled in command mode, restarted in clipboard mode

### Keyboard Behaviors in Command Mode

- [x] Shift+Arrow is disabled (no multi-select)
- [x] Right Arrow is disabled (no edit mode)
- [x] Delete key is disabled (no deletion)
- [x] Cmd+1-9 is disabled (no quick paste)

### Edge Cases

- [x] Typing "/" in the middle of search text (e.g., "hello/") does NOT trigger command mode — only when "/" is the first character
- [x] Buffered keystrokes: typing "/" before SwiftUI focus is ready correctly triggers command mode
- [x] External caffeinate kill (`killall caffeinate`) is detected via `terminationHandler` and badge is removed
- [x] If `caffeinate` binary is missing or fails to launch, no green dot appears (graceful failure)
- [x] Panel height stays consistent between modes (no jarring resize)

## Dependencies & Risks

**Dependencies:**
- `/usr/bin/caffeinate` — native macOS binary, no external dependencies
- No Combine dependency — uses callback pattern (`onStateChange`) matching existing codebase

**Risks:**
- **Low:** `caffeinate` could theoretically be missing on a modified macOS install → handle with `Process.run()` try/catch, keep state `.idle`
- **Low:** Menu bar badge rendering differs across macOS versions → test on current + previous major version
- **Medium:** Renaming `ClipboardPanelView` → `PanelView` touches multiple files. Git rename tracking should handle this but verify.

## File Change Summary

### New Files (5)

| File | Purpose |
|------|---------|
| `Sources/Services/CaffeinateService.swift` | Manages caffeinate subprocess lifecycle |
| `Sources/Models/SlashCommand.swift` | Protocol + CommandOption model |
| `Sources/Services/SleepCommand.swift` | `/sleep` command implementation (alongside CaffeinateService) |
| `Sources/Views/CommandRowView.swift` | Row view for command list |
| `Sources/Views/CommandOptionRowView.swift` | Row view for command options |

### Modified Files (4)

| File | Changes |
|------|---------|
| `Sources/Views/ClipboardPanelView.swift` | Rename to `PanelView.swift`, add mode enum, branch rendering + keyboard, cancel GRDB observation in command mode |
| `Sources/App/AppDelegate.swift` | Add `caffeinateService`, pass to panel, observe state for badge, kill on quit |
| `Sources/Views/PreviewPanel.swift` | Add countdown view for active caffeinate state |
| `Sources/Views/FloatingPanel.swift` | Update any references from `ClipboardPanelView` → `PanelView` |

## Implementation Order

```
Phase 1: CaffeinateService         ← foundation, no UI, testable alone
Phase 2: SlashCommand + SleepCommand ← protocol + first command, no UI
Phase 3: PanelView mode switching   ← the big change, UI integration
Phase 4: Preview panel countdown    ← polish
Phase 5: Menu bar badge             ← polish
```

Phases 1-2 are independent of UI. Phase 3 is the largest change. Phases 4-5 are independent polish that can be done in either order.

## References

- Brainstorm: `docs/brainstorms/2026-02-26-slash-commands-brainstorm.md`
- Menu bar icon plan: `docs/plans/2026-02-25-fix-blurry-menu-bar-icon-plan.md`
- Existing mode switching pattern: `Sources/Views/ClipboardPanelView.swift:133-204` (keyboard handler)
- Existing service pattern: `Sources/Services/ScreenCaptureService.swift` (state enum + callbacks)
- Existing defaults pattern: `Sources/Models/RetentionDefaults.swift` (UserDefaults wrapper)
