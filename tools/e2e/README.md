# Drobu recording E2E harness

Local-only end-to-end checks for the recording flow: plain-Esc stop and
panel-during-recording. **Never run in CI** — drives the real installed Drobu
app via synthetic keystrokes and writes real records into your clipboard
history.

## Status

Read [`SPIKE_RESULT.md`](./SPIKE_RESULT.md) first. On the authoring machine
(macOS 26.4.1), synthetic `CGEvent`/`osascript` keystrokes did **not** reach
Drobu's Carbon hotkeys, so the automated script `recording_e2e.sh` is
**unvalidated here** and the **manual checklist in `SPIKE_RESULT.md` is the
supported verification path**. Keep the script for environments where
synthetic event delivery works.

## Prerequisites

1. **Drobu installed and running:** `pkill -x Drobu; ./build.sh --install && open /Applications/Drobu.app`
2. **Dismiss the keychain prompt** that appears after a fresh ad-hoc-signed
   install — click *Always Allow* (see SPIKE_RESULT.md). Drobu is hung until you do.
3. **Screen Recording permission** granted to Drobu (System Settings >
   Privacy & Security > Screen Recording).
4. **Accessibility permission** for your terminal app (it posts the synthetic
   keystrokes) — System Settings > Privacy & Security > Accessibility.
5. `sqlite3` and `bc` on `PATH` (both ship with macOS).

## Usage

```bash
./tools/e2e/recording_e2e.sh
```

The script checks prerequisites, then runs three scenarios. Scenarios (a) and
(b) pause ~5s for interactive region selection — drag a small region when the
overlay appears. Scenario (b) asserts the GIF lands **before** the 15s
auto-stop boundary, so a pass proves Esc (not the timer) stopped it.

Edit the `*_KEYSTROKE` variables at the top of the script if your capture/panel
hotkeys differ from the defaults (GIF Ctrl+Shift+G, video Ctrl+Shift+V, panel
Cmd+Shift+V).

## Test residue

Each run writes real GIF/video/clipboard records into your live history. They
are normal captures — delete them from the panel if unwanted. The harness only
**reads** the database (via a separate `sqlite3` connection, safe with Drobu's
WAL mode); it never writes to it.
