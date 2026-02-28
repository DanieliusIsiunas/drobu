---
title: "Add Closed Lid Mode to /sleep Command"
type: feat
date: 2026-02-27
---

# Add Closed Lid Mode to /sleep Command

## Overview

Add a "Closed Lid" mode inside the existing `/sleep` command that keeps a MacBook running when the lid is closed, turning it into a headless Mac Mini. Uses `sudo pmset disablesleep 1` combined with the existing `caffeinate` for belt-and-suspenders coverage. Activated through a new sectioned tab UI in the command options, with macOS admin auth via AppleScript and a LaunchDaemon crash safety net.

Primary use case: remote-controlling a Mac via phone (SSH, Claude Code CLI) while the laptop is in a backpack.

## Problem Statement / Motivation

`caffeinate -dims` (the current Keep Awake mode) prevents idle and display sleep but **not** lid-close sleep. On Apple Silicon, `pmset disablesleep 1` is the only reliable mechanism to prevent lid-close sleep. IOKit `PreventSystemSleep` assertions are unreliable for this on M-series chips.

## Design Decisions (from Brainstorm)

All design decisions were resolved in the [brainstorm](../brainstorms/2026-02-27-closed-lid-mode-brainstorm.md):

1. **UX:** New section within `/sleep`, not a separate command
2. **Navigation:** Sectioned options with left/right arrow tab switching
3. **Auth:** macOS admin password dialog via AppleScript (one-shot per activation)
4. **Exclusivity:** Keep Awake and Closed Lid are mutually exclusive
5. **Safety:** Time-limited (15m-4h) with LaunchDaemon crash safety net
6. **Cleanup:** `applicationWillTerminate` + LaunchDaemon backup
7. **No thermal warning:** User accepts the risk

## Technical Approach

### Critical Design: Privileged Execution

This is the first use of privileged commands in the codebase. All privileged operations use `NSAppleScript` with `do shell script "..." with administrator privileges`, which presents the standard macOS password dialog.

```swift
// Sources/Services/PrivilegedCommand.swift

import Foundation

enum PrivilegedCommandError: Error {
    case scriptCreationFailed
    case userCancelled
    case executionFailed(code: Int, message: String)
}

/// Runs a shell command with admin privileges via the macOS auth dialog.
/// Batch multiple commands with && for a single auth prompt.
@MainActor
func runPrivileged(_ command: String) throws -> String {
    let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
    let source = "do shell script '\(escaped)' with administrator privileges"

    guard let script = NSAppleScript(source: source) else {
        throw PrivilegedCommandError.scriptCreationFailed
    }

    var errorDict: NSDictionary?
    let result = script.executeAndReturnError(&errorDict)

    if let error = errorDict {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
        if code == -128 { throw PrivilegedCommandError.userCancelled }
        throw PrivilegedCommandError.executionFailed(code: code, message: message)
    }
    return result?.stringValue ?? ""
}
```

Key facts from research:
- Error code **-128** = user cancelled the auth dialog
- Authorization is **one-shot** per `executeAndReturnError` call (no session caching)
- `NSAppleScript` must be called from the **main thread** (fine since services are `@MainActor`)
- Batch commands with `&&` so a single auth prompt covers everything

### Critical Design: LaunchDaemon Safety Net

The LaunchDaemon is the primary crash/force-quit safety mechanism. It runs independently of the app as a root-level system daemon.

**Plist structure** — uses `RunAtLoad: true` with a sleep-then-reverse pattern:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clipboardhistory.disablesleep-reversal</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/bin/sleep 3600; /usr/bin/pmset disablesleep 0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/disablesleep-reversal.log</string>
</dict>
</plist>
```

**Lifecycle:**
- Written to `/tmp/` first (no privileges needed), then copied to `/Library/LaunchDaemons/` in the same privileged batch as `pmset disablesleep 1`
- Must be `root:wheel` with mode `644` (launchd rejects incorrect ownership)
- Load: `launchctl bootstrap system <path>` (modern API, not legacy `load`)
- Unload: `launchctl bootout system/<label>` (takes label, not path)
- `bootout` before `bootstrap` on re-activation to handle existing loaded daemon

**Reboot behavior:** `pmset disablesleep` persists across reboots. On reboot, the LaunchDaemon starts its `/bin/sleep N` from zero (full original duration). This is an acceptable trade-off — the safety net may run longer than intended after reboot, but it guarantees reversal. The app also audits on startup (see Phase 4).

### Critical Design: Cleanup Without Re-Auth

**Problem:** Deactivation (manual stop, mode switch, app quit) requires `pmset disablesleep 0` which needs root. But showing another auth dialog on every stop/quit is terrible UX.

**Solution:** During activation, the privileged batch also writes a cleanup script and grants it a sudoers NOPASSWD entry for the current user:

```bash
# Written during the single activation auth prompt:
# 1. Enable disablesleep
/usr/bin/pmset disablesleep 1
# 2. Write cleanup script
cat > /Library/Application\ Support/ClipboardHistory/cleanup-disablesleep.sh << 'SCRIPT'
#!/bin/sh
/usr/bin/pmset disablesleep 0
/bin/launchctl bootout system/com.clipboardhistory.disablesleep-reversal 2>/dev/null
/bin/rm -f /Library/LaunchDaemons/com.clipboardhistory.disablesleep-reversal.plist
/bin/rm -f /Library/Application\ Support/ClipboardHistory/cleanup-disablesleep.sh
/bin/rm -f /etc/sudoers.d/clipboardhistory-cleanup
SCRIPT
chmod 755 /Library/Application\ Support/ClipboardHistory/cleanup-disablesleep.sh
# 3. Grant NOPASSWD sudo for this specific script only
echo "$USER ALL=(root) NOPASSWD: /Library/Application Support/ClipboardHistory/cleanup-disablesleep.sh" > /etc/sudoers.d/clipboardhistory-cleanup
chmod 440 /etc/sudoers.d/clipboardhistory-cleanup
# 4. Write + load LaunchDaemon plist
# ... (as above)
```

Now deactivation runs `sudo /Library/Application\ Support/ClipboardHistory/cleanup-disablesleep.sh` with **no password prompt**. The script self-deletes along with its sudoers entry. This works from `applicationWillTerminate`, signal handlers, and manual stop.

### Critical Design: Panel + Auth Dialog Interaction

**Problem:** `NSAppleScript.executeAndReturnError` is synchronous/blocking. Calling it from `execute(option:)` blocks the main thread while the auth dialog is visible.

**Solution:** Make `SlashCommand.execute` async. Close the panel *before* showing the auth dialog (so it doesn't float above it), and the auth dialog stands alone:

```swift
// Updated protocol
@MainActor
protocol SlashCommand {
    // ... existing properties ...
    func execute(option: CommandOption) async
}

// In PanelView.executeOption:
private func executeOption(at index: Int) {
    guard let cmd = selectedCommand else { return }
    let opts = cmd.options()
    guard index < opts.count else { return }
    panel?.close()  // Close BEFORE auth dialog
    Task {
        await cmd.execute(option: opts[index])
    }
}
```

If auth is cancelled, the panel is already closed — user just reopens it. This matches the existing UX where the panel always closes on action.

### Architecture: ClosedLidService

Follows the established `CaffeinateService` pattern: `@MainActor` class, `State` enum, `onStateChange` callback.

```
Sources/Services/
  ClosedLidService.swift     # NEW: pmset + LaunchDaemon + caffeinate
  PrivilegedCommand.swift    # NEW: NSAppleScript helper
  CaffeinateService.swift    # MODIFIED: mutual exclusion awareness
  SlashCommand.swift         # MODIFIED: add section support
  SleepCommand.swift         # MODIFIED: dual-service adapter
```

### Architecture: Sectioned Command Options

```swift
// SlashCommand.swift - additions
struct CommandOption: Identifiable {
    let id: String
    let label: String
    let icon: String?
    let isDestructive: Bool
    let section: String?  // NEW: nil = default/only section
}

@MainActor
protocol SlashCommand {
    // ... existing ...
    var sections: [String] { get }  // NEW: empty = no sections
}

extension SlashCommand {
    var sections: [String] { [] }  // Default: no sections
}
```

### Architecture: Section Tab Navigation in PanelView

**State:** Add `activeSection: Int = 0` to PanelView.

**Keyboard model:**

| Key | Behavior |
|-----|----------|
| Left Arrow | Switch to previous section (no-op at first section) |
| Right Arrow | Switch to next section (no-op at last section) |
| Up/Down Arrow | Navigate options within active section |
| Return | Execute selected option |
| Backspace/Escape | Back to command list (unchanged) |

**Rendering:** Horizontal pill-style tabs above the options list, active tab filled with accent color.

### Architecture: Menu Bar Badge

Extend `updateMenuBarBadge` to accept an enum instead of a boolean:

```swift
enum SleepMode {
    case none
    case keepAwake
    case closedLid
}

func updateMenuBarBadge(mode: SleepMode) {
    // .none: remove badge
    // .keepAwake: green dot (NSColor.systemGreen) — unchanged
    // .closedLid: orange dot (NSColor.systemOrange)
}
```

### Four-Layer Safety Model

| Layer | Handles | Mechanism |
|-------|---------|-----------|
| 1. `applicationWillTerminate` | Normal quit, logout, restart | Runs cleanup script (no auth needed) |
| 2. Signal handlers (SIGTERM, SIGHUP) | Activity Monitor kill, system pressure | Best-effort: kill caffeinate, trust LaunchDaemon |
| 3. LaunchDaemon | Crash, SIGKILL, power loss, app deletion | Fires `pmset disablesleep 0` after timeout, survives reboots |
| 4. Startup audit | Orphaned state from previous crash | Polls `pmset -g` on launch, offers cleanup if orphaned |

### State Reconciliation

When Closed Lid is believed active, poll `pmset -g` every 30 seconds to detect external reversal (LaunchDaemon fired, user ran `pmset` manually). If `SleepDisabled` is 0 but app thinks it's active, clear state and badge.

## Implementation Phases

### Phase 1: Privileged Command Infrastructure

**Files:**
- `Sources/Services/PrivilegedCommand.swift` (new)

**Tasks:**
- [x] Create `PrivilegedCommandError` enum with `.userCancelled`, `.executionFailed`, `.scriptCreationFailed`
- [x] Implement `runPrivileged(_ command: String) throws -> String` using `NSAppleScript`
- [x] Handle error code -128 as user cancellation
- [x] Test with a simple privileged command (`whoami` → should return "root")

### Phase 2: ClosedLidService

**Files:**
- `Sources/Services/ClosedLidService.swift` (new)

**Tasks:**
- [x] Create `@MainActor` class with `State` enum (`.idle`, `.active(startDate:, duration:)`)
- [x] Implement `start(duration:)`:
  - Generate reversal plist via `PropertyListSerialization`
  - Write plist to temp file
  - Run single privileged batch: pmset on + write cleanup script + sudoers entry + copy plist + chown/chmod + launchctl bootstrap
  - Start companion `caffeinate -dims -t N` process
  - Handle `.userCancelled` gracefully (no state change)
- [x] Implement `stop()`:
  - Run cleanup script via `sudo` (no auth prompt due to sudoers entry)
  - Kill caffeinate process
  - Reset state to `.idle`
- [x] Implement `cleanup()` for `applicationWillTerminate`:
  - Same as `stop()` but best-effort (no throws)
- [x] Implement `isDisableSleepActive() -> Bool`:
  - Run `pmset -g`, parse for `SleepDisabled 1`
  - No root needed for reading
- [x] Add `onStateChange` callback
- [x] Add caffeinate `terminationHandler` with `@MainActor` dispatch (match CaffeinateService pattern)
- [x] Add 30-second state reconciliation timer (poll `pmset -g` when active)

### Phase 3: Mutual Exclusion + SleepCommand Adapter

**Files:**
- `Sources/Services/SleepCommand.swift` (modified)
- `Sources/Services/CaffeinateService.swift` (modified)
- `Sources/Services/SlashCommand.swift` (modified)

**Tasks:**
- [x] Add `section: String?` to `CommandOption`
- [x] Add `sections: [String]` to `SlashCommand` protocol with default `[]`
- [x] Update `SleepCommand` to accept both `CaffeinateService` and `ClosedLidService`
- [x] `SleepCommand.sections` returns `["Keep Awake", "Closed Lid"]`
- [x] `SleepCommand.options()` returns options tagged with section names
- [x] "Stop" option appears only in the section of the currently active mode
- [x] `SleepCommand.execute(option:)` dispatches to correct service based on option section
- [x] Before activating either mode, stop the other (mutual exclusion)
- [x] Make `execute` async to support auth dialog
- [x] Update `isActive` to check either service
- [x] Update `activeStatusView()` to show mode-appropriate label ("Keep Awake" vs "Closed Lid Mode") + countdown

### Phase 4: Startup Audit + Signal Handlers

**Files:**
- `Sources/App/AppDelegate.swift` (modified)
- `Sources/Services/ClosedLidService.swift` (modified)

**Tasks:**
- [x] In `applicationDidFinishLaunching`: check `isDisableSleepActive()` + whether app has an active session
- [x] If orphaned `disablesleep` detected with no LaunchDaemon plist: log warning, attempt cleanup on next admin auth opportunity
- [x] If orphaned with LaunchDaemon present: log, let daemon handle it
- [x] Install `DispatchSource` signal handlers for SIGTERM/SIGHUP that call `closedLidService.cleanup()`
- [x] Add `closedLidService.cleanup()` to `applicationWillTerminate`

### Phase 5: Sectioned Tab UI in PanelView

**Files:**
- `Sources/Views/PanelView.swift` (modified)
- `Sources/Views/CommandItemRow.swift` (possibly modified)

**Tasks:**
- [x] Add `@State var activeSection: Int = 0` to PanelView
- [x] Filter command options by active section name
- [x] Render section tabs as horizontal pills above options list when command has sections
- [x] Active tab: accent-colored background, inactive: subtle background
- [x] Left/right arrow keys switch sections in `commandOptions` mode
  - Left on first section: no-op (boundary stop)
  - Right on last section: no-op (boundary stop)
  - Reset cursor to 0 on section switch
- [x] Backspace/Escape still go back to command list (unchanged)
- [x] Reset `activeSection = 0` when entering command options mode
- [x] When a mode is active, default to that mode's section on open
- [x] Show section hint in footer: "←→ switch section  ↑↓ navigate  ↵ select"

### Phase 6: Menu Bar Badge + Polish

**Files:**
- `Sources/App/AppDelegate.swift` (modified)

**Tasks:**
- [x] Replace `updateMenuBarBadge(isActive: Bool)` with `updateMenuBarBadge(mode: SleepMode)`
- [x] Green dot for Keep Awake, orange dot for Closed Lid, no dot for idle
- [x] Wire both services' `onStateChange` callbacks to badge update
- [x] Inject both services into `SleepCommand` in `showPanel()`

## Acceptance Criteria

### Functional

- [ ] User can switch between "Keep Awake" and "Closed Lid" sections with left/right arrows
- [ ] Selecting a Closed Lid duration shows the macOS admin password dialog
- [ ] After successful auth: `pmset -g` shows `SleepDisabled 1`, caffeinate is running, LaunchDaemon is loaded
- [ ] "Stop" reverses all three: pmset off, daemon unloaded+deleted, caffeinate killed — **without** another auth prompt
- [ ] Activating Keep Awake while Closed Lid is active stops Closed Lid first (no auth prompt for reversal)
- [ ] Activating Closed Lid while Keep Awake is active stops Keep Awake first
- [ ] Cancelling the auth dialog leaves the app in its previous state (no partial activation)
- [ ] Timer expiry: caffeinate exits, app detects and reverses pmset + cleans up daemon
- [ ] App quit (`applicationWillTerminate`): pmset reversed, daemon cleaned up
- [ ] If app crashes while Closed Lid is active, LaunchDaemon fires `pmset disablesleep 0` after timeout
- [ ] Menu bar shows green dot for Keep Awake, orange dot for Closed Lid, no dot when idle
- [ ] Preview panel shows "Keep Awake" or "Closed Lid Mode" label with countdown
- [ ] On startup, orphaned `disablesleep 1` state is detected and logged

### Keyboard Navigation

- [ ] Right arrow switches to next section tab
- [ ] Left arrow switches to previous section tab
- [ ] Arrows at section boundaries are no-ops (no wrapping)
- [ ] Up/down navigate within active section only
- [ ] Cursor resets to 0 on section switch
- [ ] Backspace and Escape go back to command list from any section
- [ ] Return executes the selected option in the active section

### Safety

- [ ] `pmset disablesleep 0` is guaranteed to run via at least one of: app cleanup, signal handler, LaunchDaemon
- [ ] LaunchDaemon survives app crash, force-quit, and reboot
- [ ] Cleanup script + sudoers entry are self-deleting (no permanent privilege escalation)
- [ ] No partial activation states: either all three (pmset + daemon + caffeinate) succeed, or none do
- [ ] Concurrent rapid activations are serialized (no race conditions on plist writes)

## Dependencies & Risks

**Dependencies:**
- Existing slash command system (already on `feat/slash-commands-caffeinate` branch)
- `CaffeinateService` must be stable before building `ClosedLidService`

**Risks:**

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `pmset disablesleep` removed in future macOS | Low | High | Check on startup, disable section if unavailable |
| User has no admin password (standard user, MDM) | Medium | Medium | Auth dialog handles this; app shows no error beyond the native dialog |
| sudoers.d approach rejected by corporate security tools | Low | Medium | Fall back to re-auth on stop; LaunchDaemon still covers crashes |
| App killed via SIGKILL during activation (partial state) | Very Low | High | Startup audit detects orphaned state |
| Plist write race on rapid re-activation | Low | Medium | Guard `execute` with `isActivating` flag to prevent concurrent calls |

## References

### Internal
- Brainstorm: `docs/brainstorms/2026-02-27-closed-lid-mode-brainstorm.md`
- Slash commands plan: `docs/plans/2026-02-26-feat-slash-commands-caffeinate-plan.md`
- CaffeinateService: `Sources/Services/CaffeinateService.swift`
- SleepCommand: `Sources/Services/SleepCommand.swift`
- PanelView keyboard handler: `Sources/Views/PanelView.swift:552`
- Menu bar badge: `Sources/App/AppDelegate.swift:156`

### External
- [pmset man page](https://ss64.com/mac/pmset.html) — `disablesleep` persists across reboots
- [launchctl modern API](https://gist.github.com/masklinn/a532dfe55bdeab3d60ab8e46ccc38a68) — `bootstrap`/`bootout` vs legacy `load`/`unload`
- [Apple: Creating Launch Daemons](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [NSAppleScript error handling](https://developer.apple.com/documentation/foundation/nsapplescripterrornumber) — error -128 = user cancelled
- [Moarram/wake](https://github.com/Moarram/wake) — reference implementation using pmset disablesleep
