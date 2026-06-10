# Apple Silicon Display Power Gotchas

Verified live on Apple M4 Pro / macOS 26.3.1 (display-off-on-lid-close feature,
2026-06-10). Spike record: `tools/spikes/display-off-spike.md`.

## What works: `pmset displaysleepnow` (root), even under `disablesleep 1`

- The display-sleep and system-sleep assertion lanes are **independent** on
  Apple Silicon: with `pmset disablesleep 1` held, `PreventUserIdleDisplaySleep`
  stays 0 and display sleep is honored. You are not fighting powerd.
- `pmset displaysleepnow` is absent from `pmset`'s usage text on macOS 26 but
  exists, exits 0, and **holds the panel dark for the full lid-closed interval**
  under `disablesleep 1`, on battery and AC. No re-wake from `UserIsActive`.
- It sleeps **ALL displays**, externals included — desirable for Drobu's Closed
  Lid (user-confirmed preference; do NOT add a display-topology guard).
- No explicit restore is needed: opening the lid (HID wake) relights the panel.
  If "require password after display sleep" is on, the user lands on the lock
  screen — expected, not a bug.
- Audio (e.g. Spotify) continues across the display-off — display sleep does
  not touch the audio path.

## What is DEAD on Apple Silicon (do not implement)

- `kIOPMMessageClamshellStateChange` interest notifications never fan out to
  user space on M-series. Poll the `AppleClamshellState` property on
  `IOPMrootDomain` instead (CFBoolean; the kernel sets it BEFORE messaging
  clients, so the poll is authoritative). 500ms `.common`-mode timer works;
  the edge shows within ~1 tick of physical close.
- `IODisplayConnect` / `IODisplaySetFloatParameter` brightness: matches **zero**
  services (`ioreg -r -c IODisplayConnect`). The panel lives on
  `IOMobileFramebuffer`. Any Intel-era dim code is a silent no-op.
- `IODisplayWrangler` + `IORequestIdle`: the node exists but is an unwired
  placeholder (absent from `pmset -g powerstate`).
- SkyLight `SLSDisplayPowerControlClient`: needs a private entitlement AMFI
  rejects on Developer ID. `DisplayServicesSetBrightness(id, 0)` is minimum
  brightness only (panel stays lit) — degraded last resort, wasn't needed.
