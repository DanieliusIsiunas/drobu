# AppKit Window/Panel Gotchas

## Programmatic NSWindow/NSPanel + ARC → set `isReleasedWhenClosed = false` ALWAYS

A window created in code (`NSWindow(contentRect:…)` / an `NSPanel` subclass)
defaults **`isReleasedWhenClosed = true`**. That flag is a pre-ARC artifact: on
`close()`, AppKit sends the window an extra, unbalanced release (historically an
`-autorelease`). Under ARC, our windows are *also* owned by a Swift strong
reference — a `let` captured in a closure, or a stored `var selectionPanel`. So
`close()` injects a **-1 that ARC doesn't know about** → the window is
**over-released**.

The crash is **deferred**: the extra release lands one cycle later when the main
run loop drains its autorelease pool, walking the already-freed window. The
signature is unmistakable and has **no app frames** in it (and no NSException —
it's a raw `EXC_BAD_ACCESS` / `KERN_INVALID_ADDRESS`):

```
objc_release
AutoreleasePoolPage::releaseUntil(objc_object**)
objc_autoreleasePoolPop
_CFAutoreleasePoolPop
-[NSAutoreleasePool drain]
-[NSApplication run]
NSApplicationMain
```

Because it's timing-dependent (gated on the freed memory being re-touched), it
looks **intermittent** — "worked 4 times, crashed the 5th." It is not
intermittent; it's a guaranteed over-release that surfaces probabilistically.

**Rule:** every programmatically-created `NSWindow`/`NSPanel` that is owned by an
ARC reference (all of ours are) MUST set `isReleasedWhenClosed = false` right
after init. Then ARC is the sole owner and `close()` performs no release. Audit:

```bash
grep -rn "isReleasedWhenClosed" Sources/   # every window class must appear
```

Drobu's window classes all set it: `FloatingPanel`, `ActivationPanel`,
`SettingsPanel`, `LargePreviewPanel`, `RecordingIndicatorWindow` (whose comment
spells it out: *"Required for ARC — prevents double-free on close()"*).

### Two that regressed (both fixed 2026-06-18, v1.9.2)

- **`FloatingPanel.showCopiedNotification()` HUD `NSWindow`** — the v1.9.1
  shipped crash. A user pastes, the HUD shows, and its `hud.close()` (fired ~1.8s
  later from the dismiss closure that is the window's *only* strong owner)
  over-releases it. It was the lone window in the codebase missing the flag.
- **`RegionSelectionPanel`** (screen/video capture region select) — same hazard,
  latent. Owned by `ScreenCaptureService`/`VideoCaptureService`'s strong
  `selectionPanel` and self-`close()`s from its callbacks. Safe to add the flag
  because every close path also nils that ref (no leak).

## A permission-gated crash branch can make a TCC problem look like a code crash

The HUD path above runs only in the `else` of `if AXIsProcessTrusted()` — i.e.
**only when Accessibility is NOT granted** (no Cmd+V auto-paste, so it shows the
"Copied! Paste with ⌘V" HUD instead). So the over-release bit *only* users whose
Accessibility grant was missing/ineffective. A "messed-up permissions" report and
a "crashes on paste" report were the **same root cause**: broken Accessibility →
HUD branch taken → over-release.

**Triage lesson:** when a crash reproduces for some users and not others, check
whether the crashing branch is **permission-gated** (`AXIsProcessTrusted()`,
`CGPreflightScreenCaptureAccess()`, pasteboard `accessBehavior`). The
discriminator may be a TCC grant, not the input data.

## Catching a deferred over-release: NSZombie on the real binary

The pool-drain stack tells you *that* an autoreleased object was over-released,
not *which* one. To get the class without symbolicating: relaunch the **binary
directly** (env vars don't pass through `open`) with zombies on, then trigger the
path — the trap names the class.

```bash
NSZombieEnabled=YES NSDeallocateZombies=NO MallocStackLogging=YES \
  /Applications/Drobu.app/Contents/MacOS/Drobu 2>&1 | tee /tmp/drobu-zombie.log
# trap prints: *** -[<Class> release]: message sent to deallocated instance 0x…
# then: malloc_history <pid> 0x…   for the allocation backtrace
```

NSZombie changes timing (objects never freed), so a genuine over-release that
SIGSEGVs in release becomes a clean "message sent to deallocated instance" naming
the class — for these window bugs, `NSWindow`/`NSPanel`.
