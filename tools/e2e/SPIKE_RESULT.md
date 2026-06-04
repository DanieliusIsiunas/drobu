# E2E Harness Spike Result

**Date:** 2026-06-04
**Question (plan U5 execution note):** Do synthetic keystrokes trigger Drobu's Carbon `RegisterEventHotKey` hotkeys, so an automated harness can drive the recording flow?

## Finding: synthetic events do NOT reliably drive Carbon hotkeys here

Two self-contained spikes were run on this dev machine (macOS 26.4.1, Apple Silicon). Each registered its **own** modifier-less Carbon hotkey in-process and posted a synthetic key for it:

1. Plain run-loop (`CFRunLoop`) + `CGEvent(...).post(tap: .cghidEventTap)` → **NO-FIRE**
2. `NSApplication` (`.accessory`) event loop + same synthetic post → **NO-FIRE**

Both handlers never fired. `osascript` System Events `key code` injection against the running app also produced no observable effect.

**Conclusion:** on this OS, `CGEvent`-posted keystrokes are not delivered to Carbon hotkey dispatch (consistent with Secure Event Input / WindowServer synthetic-event handling on recent macOS). The automated harness's load-bearing assumption does not hold here, so per the plan's spike-first gate the deliverable for this iteration is this document plus the manual checklist below. `recording_e2e.sh` ships as the ready-to-run automated path for environments where synthetic delivery *does* work; it is **unvalidated on this machine**.

### Secondary finding (environment, not code)

After `./build.sh --install` (ad-hoc signing), the freshly installed Drobu hangs at launch on a **one-time keychain authorization prompt** — `sample` showed the main thread blocked in `SecKeychainItemCopyContent` during `LicenseManager` static init, before any first-run log line. The keychain ACL no longer matches the re-signed binary, so macOS shows a blocking "allow access" dialog.

**Before manual verification:** bring Drobu to the foreground and click **Always Allow** on the keychain dialog (once per rebuild). Until dismissed, Drobu processes no hotkeys and shows no windows.

## Manual verification checklist

Run after `pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app` and dismissing the keychain prompt. Tail the log in another pane: `tail -f "$HOME/Library/Application Support/ClipboardHistory/app.log"`.

### Feature 1 — plain Esc stops and saves

- [ ] Start a **GIF** recording (Ctrl+Shift+G), select a region, record briefly, press **Esc** → GIF appears at the top of the panel. Log shows `Esc stop hotkey claimed` then `…released`.
- [ ] Start a **video** recording (Ctrl+Shift+V), press **Esc** → video saved.
- [ ] While **idle**, focus another app and press Esc (e.g. dismiss a dialog) → Esc works normally; Drobu does not intercept it.
- [ ] During **region selection**, press Esc → selection cancels (unchanged behavior); no recording starts.
- [ ] During **encoding/finalizing** (right after stopping), press Esc → reaches the focused app; Drobu does not intercept (log shows the claim was released).
- [ ] **Rapid double-Esc** during a GIF recording → exactly one GIF saved, no duplicate.
- [ ] **Cmd+Esc** during a recording still stops and saves.

### Feature 2 — panel during recording

- [ ] Start a **video** recording, press the **panel hotkey** (Cmd+Shift+V) → panel opens over the region and is visible in the resulting video. Log shows `panel shown`.
- [ ] Press the panel hotkey again mid-recording → panel closes; recording continues.
- [ ] Paste an item from the panel mid-recording → paste works; no duplicate history entry; recording unaffected.
- [ ] Let a recording stop while the panel is open → the new GIF/video row appears at the top via live observation.
- [ ] During **region selection**, press the panel hotkey → still ignored (panel does not open).
- [ ] Click the recorded app while the panel is open mid-recording → panel auto-closes (existing `resignKey` behavior, accepted).

### HUD

- [ ] During any recording, the HUD reads **"Esc or hotkey to stop"** with no clipping, positioned outside the capture region.
