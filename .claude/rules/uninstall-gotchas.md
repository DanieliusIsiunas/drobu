# In-App Uninstall Gotchas

Learned building the Settings-only "Uninstall Drobu…" feature. Applies to any
future work on the uninstall path or anything that tears down the daemon.

## Drag-to-trash cannot be hooked; SMAppService registrations never auto-clean

Verified against Apple DTS guidance (Quinn) and live behavior:

- There is **no supported hook** for running cleanup when an app bundle is
  dragged to the Trash — no Launch Services callback, no `NSWorkspace`
  notification, nothing. A `kqueue`/FSEvents watchdog on the bundle path is
  unsupported AND misfires on every Sparkle update (the bundle is transiently
  replaced) — do not build one.
- Deleting the app does **not** unregister an `SMAppService` daemon or login
  item. The orphaned entry persists in System Settings → Login Items, the user
  **cannot remove it from the UI**, and the running daemon keeps its mapped
  inode until reboot. The only clean removal is the app calling
  `SMAppService.unregister()` itself — hence an in-app uninstall is structurally
  necessary for a daemon-bearing app, not a convenience.

## Teardown ordering is load-bearing

`UninstallService` runs: **disable (reverse active session) → teardown (erase
root state) → unregister → resetConnection → mainApp.unregister → optional data
wipe → (residual summary) → schedule trash → terminate**.

- **Reverse the session FIRST.** If you `unregister()` (BTM SIGKILLs the daemon)
  while a Closed Lid session is active, `pmset disablesleep` is left applied with
  its only reversal owner deleted — the Mac can't sleep until reboot. Call
  `daemon.disableBounded()`/`disable()` before removing the daemon (mirrors
  `ClosedLidService.cleanup()`).
- **The self-delete must NOT gate on the app PID alone.** `unregister()` is async
  (BTM tears down after it returns), so the app can quit while the root daemon is
  still live. The detached trasher waits for the daemon process to be absent
  (`pgrep -qx DrobuDaemon`) too, and re-verifies the bundle's `CFBundleVersion`
  before trashing (aborts if a Sparkle update swapped it).

## The daemon's removable root state is its support dir, NOT a LaunchDaemons plist

`SMAppService` carries the daemon plist *inside the bundle*
(`Contents/Library/LaunchDaemons/`) and removes the registration record on
`unregister()` — there is **no** daemon-writable `/Library/LaunchDaemons/*.plist`
to delete (only the swept legacy one). The only genuinely root-owned removable
state is `DaemonConstants.supportDirectory` (`daemon-session.json` + `daemon.log`).
Scope the `teardown` XPC selector to exactly those, gated on `FileGuards`
(lstat/symlink-refusing) — root deletion in an installer-writable tree invites
planted-symlink redirection.

Remove the **state file before the log**, then the directory: after the dir is
gone, `DaemonLog.write` no-ops (`createFile` won't recreate a missing parent), so
no residue is resurrected in the brief window before `unregister` reaps the
process.

## Adding an XPC selector bumps the protocol version — uninstall must bypass remediation

Adding `teardown` bumped `drobuDaemonProtocolVersion` 2 → 3 (and the
`DaemonConstantsTests` pin). A version bump makes a field-updated app see the old
running daemon as a mismatch on the next Closed Lid activation — handled by the
existing `reinstall()` machinery. But the **uninstall path must tolerate a
mismatched/old daemon** (call `teardown` best-effort, skip on a `nil` reply, then
`unregister` regardless) — never route uninstall through `reinstall()`; repairing
a daemon you're about to remove is a loop.

## The license/trial Keychain is preserved on purpose

`DataEraser` has no Security/Keychain code path. The uninstall deliberately
leaves `trial-start`/`last-seen` (the offline anti-trial-farming anchor) and
`active-license` (so reinstall stays activated). The confirmation copy discloses
this. `DataEraser` is also distinct from "Delete all history" — the latter keeps
the DB file + settings so the running app stays usable; the eraser removes the
whole `~/Library/Application Support/ClipboardHistory` directory + the
`UserDefaults` domain (a clean slate, run only as the app quits).
