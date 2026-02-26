# Closed Lid Mode Brainstorm

**Date:** 2026-02-27
**Status:** Ready for planning

## What We're Building

A "Closed Lid" mode inside the existing `/sleep` command that keeps a MacBook running when the lid is closed — turning it into a headless Mac Mini. The primary use case is remote-controlling a Mac via phone (e.g., Claude Code CLI via SSH) while the laptop is in a backpack.

**Mechanism:** `sudo pmset disablesleep 1` (proven on Apple Silicon + macOS Sequoia/Sonoma/Tahoe). Combined with the existing `caffeinate` for idle sleep prevention.

## Why This Approach

- `caffeinate -dims` (current) prevents idle/display sleep but NOT lid-close sleep
- `pmset disablesleep 1` is the only reliable way to prevent lid-close sleep on Apple Silicon
- Amphetamine uses a similar undocumented API but won't disclose details
- IOKit `PreventSystemSleep` assertions are unreliable for lid-close on M-series chips

## Key Decisions

### 1. Command UX: New option in existing `/sleep` command
Not a separate command. User already knows `/sleep` prevents sleep — Closed Lid is a stronger version.

### 2. Sectioned options with tab navigation
The `/sleep` options list gets two sections, navigable with left/right arrow keys:

```
┌────────────────────────────────┐
│  [● Keep Awake]  [ Closed Lid ] │
├────────────────────────────────┤
│  ▶ 15 minutes                  │
│    30 minutes                  │
│    1 hour                      │
│    2 hours                     │
│    4 hours                     │
└────────────────────────────────┘

  ←→ switch section  ↑↓ navigate  ↵ select
```

This requires extending `CommandOption` with a section concept and updating the keyboard handler in PanelView to support left/right navigation in command options mode.

### 3. Auth: macOS authorization dialog
When user selects a Closed Lid option, show the standard macOS admin password prompt via AppleScript `do shell script ... with administrator privileges`. One-time per activation. No password stored.

### 4. Modes are mutually exclusive
Activating Keep Awake cancels any active Closed Lid session, and vice versa. Simplest mental model — there's only ever one active sleep prevention mode.

### 5. Safety: Time-limited with LaunchDaemon crash safety
Same durations as Keep Awake: 15m, 30m, 1h, 2h, 4h.

**Crash safety net:** On activation, write a one-shot LaunchDaemon plist to `/Library/LaunchDaemons/com.clipboardhistory.disablesleep-reversal.plist`. This runs as root (no sudo needed at reversal time) and executes `pmset disablesleep 0` after the chosen duration expires. The initial admin auth prompt covers both the `pmset disablesleep 1` and writing this plist.

```
/Library/LaunchDaemons/
  com.clipboardhistory.disablesleep-reversal.plist

  ProgramArguments: /usr/bin/pmset disablesleep 0
  StartInterval: <duration_seconds>
  Runs as root → no sudo needed at reversal time
  Removed on normal cancellation/expiry by app
```

On normal cancellation or app quit: reverse `pmset disablesleep 0` and remove the LaunchDaemon plist (both via the existing admin authorization or a helper script written during activation).

### 6. No thermal warning
User is aware of thermal implications. No modal alert.

### 7. Cleanup on app quit
`applicationWillTerminate` reverses `pmset disablesleep 0` if Closed Lid mode is active. LaunchDaemon remains as backup in case this fails.

## Implementation Sketch

### Service layer
- New `ClosedLidService` managing `pmset disablesleep` state + LaunchDaemon lifecycle
- Single admin auth prompt via AppleScript runs a shell script that: (a) sets `pmset disablesleep 1`, (b) writes the LaunchDaemon reversal plist, (c) loads it with `launchctl`
- `stop()` runs the reverse: `pmset disablesleep 0`, unloads + deletes the plist
- Also starts a `caffeinate` process for idle sleep prevention (belt + suspenders)
- `CaffeinateService` gains awareness of `ClosedLidService` for mutual exclusion

### Protocol changes
- `CommandOption` gains a `section: String?` property (nil = default/only section)
- `SlashCommand` gains a `sections: [String]` property (default `[]` = no sections)
- `SleepCommand.options()` returns options across two sections: "Keep Awake" and "Closed Lid"
- "Stop" option appears in whichever section is currently active

### UI changes
- `PanelView` command options mode: render section tabs at top of options list
- Left/right arrows switch active section, cursor resets to 0
- Only options matching the active section are displayed
- Preview panel shows section-appropriate description/countdown
- Section tabs show which section is selected (filled dot vs empty)

### State & badge
- Menu bar badge: green dot for Keep Awake, different color/icon for Closed Lid
- `activeStatusView()` shows which mode is active ("Keep Awake" vs "Closed Lid") + countdown

## Activation Flow

1. User opens panel, types `/sleep`, selects the command
2. Options show with "Keep Awake" tab active (default)
3. User presses → to switch to "Closed Lid" tab
4. User selects "1 hour" and presses Return
5. macOS admin password dialog appears (standard system UI)
6. On auth success: `pmset disablesleep 1` runs, LaunchDaemon plist written + loaded, caffeinate started
7. Panel closes, menu bar badge updates
8. User closes lid — Mac keeps running, network stays up
9. After 1 hour: caffeinate exits, LaunchDaemon fires `pmset disablesleep 0`, app detects state change → badge clears
