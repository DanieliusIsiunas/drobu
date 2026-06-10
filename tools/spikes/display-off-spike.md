# display-off-spike.md — Spike U1 for the display-off-on-lid-close plan

**QUESTION:** With a Closed Lid session active (`pmset disablesleep 1` held by the
daemon), does `pmset displaysleepnow` extinguish the M4's internal panel **and
keep it dark for the full lid-closed interval** — or does something
(`UserIsActive` assertion, lid-sensor event) re-wake it?

This is the make-or-break gate from
`docs/plans/2026-06-10-001-feat-display-off-lid-close-plan.md` (R6). The code on
this branch implements the **simple path** (daemon runs `pmset displaysleepnow`
on the lid-close edge). U1.1 confirms or rejects it:

- **U1.1 passes** → ship as built.
- **U1.1 fails, U1.2 passes** → bounded follow-up: daemon lowers `displaysleep`
  to 1 min for the session and restores it (plan's fallback path).
- **Both fail** → degraded `DisplayServicesSetBrightness(0)` (plan's last resort).

This is a MANUAL protocol (requires a human at the machine — the screen itself
is the thing under test, so observe from a second device over SSH). Like
`clamshell-spike.swift`, it is a throwaway probe outside the SPM build graph.

**Target:** Apple M4 Pro, macOS 26.3.1. Record outcomes at the bottom and copy
the verdict into `.claude/rules/applesilicon-display.md`.

---

## Already answered — do NOT re-spend spike budget

| Question | Answer | When/How |
|---|---|---|
| Does `pmset displaysleepnow` exist on macOS 26.3.1? | Yes — absent from usage text but exits 0 | Live probe 2026-06-10 |
| Is `IODisplayWrangler` usable? | No — placeholder node, not in `pmset -g powerstate` | Live probe 2026-06-10 |
| Does `AppleClamshellState` exist lid-open? | Yes — `ioreg -r -c IOPMrootDomain -d 1 \| grep Clamshell` → `"AppleClamshellState" = No` | Live probe 2026-06-10 |
| Are display-sleep and system-sleep lanes independent under `disablesleep 1`? | Yes — `PreventUserIdleDisplaySleep = 0`, `displaysleep` honored | Live probe 2026-06-10 |
| **U1.4:** does `IODisplayConnect` match anything (is the old dim path dead)? | **Dead** — `ioreg -r -c IODisplayConnect` → 0 entries; panel is on `IOMobileFramebuffer` (×3) | Re-confirmed 2026-06-10 on this branch |

---

## Setup (once)

1. **Second device:** enable Remote Login (System Settings → General → Sharing →
   Remote Login) and SSH in from a phone/another Mac: `ssh <user>@<mac>.local`.
2. **Dim the room** (or nearly close the lid to a sliver) — backlight bleed
   around the closed lid seam is the visual signal that the panel is lit.
3. **Start a Closed Lid session** in Drobu (e.g. 1 hour) and verify the daemon
   holds sleep off:

   ```bash
   pmset -g | grep SleepDisabled        # want: SleepDisabled    1
   ```

4. In the SSH session, start the two watchers (separate terminals or `&`):

   ```bash
   # Watcher A — assertion lanes (the re-wake suspects):
   while true; do printf '%s  ' "$(date '+%T')"; pmset -g assertions | grep -E 'UserIsActive|PreventUserIdleDisplaySleep' | tr '\n' ' '; echo; sleep 2; done
   ```

   ```bash
   # Watcher B — authoritative display power events:
   pmset -g log | grep -E 'Display is turned (on|off)' | tail -3   # re-run to poll
   ```

---

## U1.1 — `displaysleepnow` stay-dark under `disablesleep` (MAKE-OR-BREAK)

Mirror the production order: **lid closes first, then the actuator fires** (in
production the daemon fires it within ~500ms of the close edge; here you are
the daemon, over SSH).

1. With the Closed Lid session active, **close the lid**. Panel stays lit
   (today's bug — bleed visible at the seam).
2. From SSH: `sudo pmset displaysleepnow`
3. **Observe ≥5 minutes:** Does the bleed disappear immediately and STAY gone?
   Watch Watcher A for `UserIsActive` re-firing / `PreventUserIdleDisplaySleep`
   flipping to 1, and re-run Watcher B for a `Display is turned on` event after
   your off event.
4. **Re-open the lid.** Panel should wake on its own (lid/HID wake) — the simple
   path deliberately has no explicit restore; confirm none is needed.
5. Also worth one repeat **on battery** (AC vs battery power-policy differences).
6. **If you ever use an external display:** repeat once with it attached —
   `displaysleepnow` may blank ALL displays, not just the internal panel.
   The plan defers external-display handling, but this observation decides
   whether a display-topology guard (skip displayOff when a non-builtin
   display is online) is needed in the follow-up.

**PASS:** dark for the full closed interval, wakes on open → ship simple path.
**FAIL:** re-lights within seconds/minutes → record what fired in Watcher A/B, go to U1.2.

## U1.2 — fallback: `displaysleep 1` (only if U1.1 fails)

1. Record the current value first: `pmset -g | grep " displaysleep"` (note it!).
2. From SSH: `sudo pmset -a displaysleep 1`
3. Close the lid, wait ~90s (1 min timeout + slack). Does the panel go dark and
   stay dark? Same watchers as U1.1.
4. **RESTORE the prior value:** `sudo pmset -a displaysleep <prior>` — do not
   skip; this mutates a persistent user setting.

**PASS:** the follow-up implements the daemon-owned save/lower/restore path
(plan U3 fallback). **FAIL:** degraded brightness path; document the limitation.

## U1.3 — detection sanity: `AppleClamshellState` flips under `disablesleep`

The branch's poll (500ms) needs the property to flip on physical close even
when the sleep path is suppressed. From SSH:

```bash
while true; do printf '%s  ' "$(date '+%T.%3N' 2>/dev/null || date '+%T')"; ioreg -r -c IOPMrootDomain -d 1 | grep AppleClamshellState; sleep 0.5; done
```

Close → expect `= Yes` within ~1 tick; open → `= No`. (Kernel sets the property
before messaging clients, so this should hold; verify on hardware once.)

**Bonus end-to-end check:** instead of the manual `sudo` in U1.1 step 2, just
close the lid with this branch's build installed — the app's poll should fire
`displayOff()` itself within ~500ms. `app.log` will show the close edge and the
daemon log (`/Library/Application Support/...` per DaemonLog) the actuator call.

---

## Outcome record — RUN 2026-06-10 (M4 Pro, macOS 26.3.1) — SIMPLE PATH CONFIRMED

Run as the end-to-end check (installed build, lid physically closed; the app's
own poll → daemon `displayOff()` chain did the actuation — no manual `sudo`).

| Check | Result | Notes (assertions observed, timings, AC/battery) |
|---|---|---|
| U1.1 displaysleepnow stay-dark | ✅ pass | Battery AND AC: panel dark for the closed interval; Spotify audio kept playing throughout (stay-awake intact, R8) |
| U1.1 wake-on-open without explicit restore | ✅ pass | Lid open → lock screen (the user's "require password after display sleep" setting — expected macOS behavior, not a bug); unlock and continue |
| U1.2 displaysleep=1 (only if U1.1 failed) | ✅ skipped | Not needed — the fallback path stays unbuilt |
| U1.3 AppleClamshellState flip ≤1 tick | ✅ pass (implicit) | Panel went dark promptly after physical close via the 500ms poll → edge → XPC chain |
| U1.4 IODisplayConnect dead | ✅ confirmed 2026-06-10 | 0 matches; IOMobileFramebuffer ×3 is the panel path |
| External display (bonus, AC) | ✅ observed | `displaysleepnow` turns off external displays too — user explicitly LIKES this; the deferred display-topology guard is NOT wanted |
