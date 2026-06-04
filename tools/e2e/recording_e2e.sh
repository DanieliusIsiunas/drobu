#!/bin/bash
# End-to-end test harness for Drobu recording flow.
#
# LOCAL-ONLY. Never run in CI — it drives the real installed Drobu app via
# synthetic keystrokes and writes real records into your live clipboard
# history. See README.md for prerequisites and SPIKE_RESULT.md for the
# known limitation on synthetic-event delivery (this harness's load-bearing
# assumption, which did NOT hold on the dev machine at authoring time).
#
# Scenarios:
#   (a) video: start recording, wait 3s, Esc -> assert a video record saved
#   (b) gif:   start recording, wait 3s, Esc -> assert a gif record saved
#              AND that it landed well before the 15s auto-stop, so an
#              auto-stop-produced GIF cannot satisfy the assertion
#   (c) panel: start video recording, toggle panel via hotkey, assert the
#              panel window appears and disappears, then Esc -> video saved
#
# Configure the hotkeys below to match your Drobu settings (defaults shown).

set -uo pipefail

DB="$HOME/Library/Application Support/ClipboardHistory/clipboard.sqlite"
LOG="$HOME/Library/Application Support/ClipboardHistory/app.log"
POLL_TIMEOUT=30          # seconds to wait for a record to appear
GIF_ESC_DEADLINE=12      # seconds; a GIF record must appear before this (< 15s auto-stop)

# Hotkeys as AppleScript `key code` + modifier lists. Defaults:
#   GIF capture  = Ctrl+Shift+G   (key code 5 = G)
#   Video capture= Ctrl+Shift+V   (key code 9 = V)
#   Panel        = Cmd+Shift+V    (key code 9 = V)
GIF_KEYSTROKE='key code 5 using {control down, shift down}'
VIDEO_KEYSTROKE='key code 9 using {control down, shift down}'
PANEL_KEYSTROKE='key code 9 using {command down, shift down}'
ESC_KEYSTROKE='key code 53'

fail() { echo "FAIL: $*" >&2; echo "--- last app.log lines ---" >&2; tail -8 "$LOG" >&2; exit 1; }
info() { echo "  $*"; }

# --- Prerequisite checks (fail fast with instructions) ---

check_prereqs() {
  echo "Checking prerequisites..."

  # Accessibility for the process that posts events (here: osascript / Terminal)
  if ! osascript -e 'tell application "System Events" to get name of first process' >/dev/null 2>&1; then
    fail "Accessibility not granted. Add your terminal app to System Settings > Privacy & Security > Accessibility."
  fi

  if ! pgrep -x Drobu >/dev/null; then
    fail "Drobu is not running. Launch it: open /Applications/Drobu.app"
  fi

  if [ ! -f "$DB" ]; then
    fail "Clipboard database not found at $DB"
  fi

  # Drobu must already hold Screen Recording permission (we can't grant it here).
  info "Assuming Drobu holds Screen Recording permission (grant it manually if a recording never starts)."

  # Abort if a recording is already in progress (would corrupt the scenario).
  # Compare the last claim vs the last release across the WHOLE log, not a fixed
  # tail window — a recording that has logged many lines since the claim would
  # be missed by a narrow tail.
  local last_claim last_release
  last_claim=$(grep -n "Esc stop hotkey claimed" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  last_release=$(grep -n "Esc stop hotkey released" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$last_claim" ] && { [ -z "$last_release" ] || [ "$last_claim" -gt "$last_release" ]; }; then
    fail "A recording appears to be in progress (Esc claim active, not yet released). Stop it before running the harness."
  fi

  echo "Prerequisites OK."
}

# --- Helpers ---

send_key() { osascript -e "tell application \"System Events\" to $1"; }

# Total records of a given kind. createdAt is stored by GRDB as a TEXT datetime
# ("yyyy-MM-dd HH:mm:ss.SSS"), so a numeric-epoch comparison would be wrong
# (SQLite sorts every TEXT value after every number, making `createdAt > <num>`
# always true). We avoid date math entirely: snapshot the count before a
# scenario and poll for it to increase.
count_records() {
  local kind="$1"
  sqlite3 "$DB" "SELECT COUNT(*) FROM clipboardItem WHERE kind='$kind';" 2>/dev/null || echo 0
}

# Poll until the record count for a kind exceeds the given baseline, or timeout.
# Echoes elapsed seconds measured from the passed scenario-start epoch (so the
# GIF discriminator can compare against the recording timeline), or -1 on timeout.
poll_for_new_record() {
  local kind="$1" baseline="$2" scenario_start="$3" timeout="$4" now elapsed cnt
  while :; do
    cnt=$(count_records "$kind")
    now=$(date +%s); elapsed=$((now - scenario_start))
    if [ "${cnt:-0}" -gt "$baseline" ]; then echo "$elapsed"; return 0; fi
    if [ "$elapsed" -ge "$timeout" ]; then echo "-1"; return 1; fi
    sleep 1
  done
}

drobu_window_count() {
  osascript -e "tell application \"System Events\" to count windows of process \"Drobu\"" 2>/dev/null || echo 0
}

# --- Scenarios ---

scenario_video_esc() {
  echo "Scenario (a): video recording stopped by Esc"
  local t0; t0=$(date +%s)
  local baseline; baseline=$(count_records "video")
  info "Starting video capture; select a small region when the overlay appears."
  send_key "$VIDEO_KEYSTROKE"
  sleep 5   # allow region selection + recording start (interactive on first run)
  info "Recording ~3s, then pressing Esc."
  sleep 3
  send_key "$ESC_KEYSTROKE"
  local elapsed; elapsed=$(poll_for_new_record "video" "$baseline" "$t0" "$POLL_TIMEOUT")
  [ "$elapsed" -ge 0 ] || fail "(a) no new video record appeared within ${POLL_TIMEOUT}s"
  info "PASS (a): video record saved ${elapsed}s after scenario start"
}

scenario_gif_esc() {
  echo "Scenario (b): GIF recording stopped by Esc (timing-discriminated)"
  local t0; t0=$(date +%s)
  local baseline; baseline=$(count_records "gif")
  info "Starting GIF capture; select a small region when the overlay appears."
  send_key "$GIF_KEYSTROKE"
  sleep 5   # ~5s interactive region selection
  info "Recording ~3s, then pressing Esc."
  sleep 3   # ~3s recording -> Esc at ~8s after scenario start
  send_key "$ESC_KEYSTROKE"
  # elapsed is measured from scenario start (t0), so it spans selection +
  # recording + encode. Esc-stop path: ~8s recording + a few s encode ~= 10s.
  # If Esc silently fails, the 15s auto-stop fires -> ~5s selection + 15s
  # recording + encode ~= 21s. GIF_ESC_DEADLINE=12 cleanly separates them.
  local elapsed; elapsed=$(poll_for_new_record "gif" "$baseline" "$t0" "$POLL_TIMEOUT")
  [ "$elapsed" -ge 0 ] || fail "(b) no new gif record appeared within ${POLL_TIMEOUT}s"
  if [ "$elapsed" -ge "$GIF_ESC_DEADLINE" ]; then
    fail "(b) gif record appeared ${elapsed}s after start (>= ${GIF_ESC_DEADLINE}s) — past the Esc window, so the 15s auto-stop likely fired, not Esc. Esc-stop NOT proven."
  fi
  info "PASS (b): gif record saved ${elapsed}s after start (< ${GIF_ESC_DEADLINE}s — inside the Esc window, before the 15s auto-stop)"
}

scenario_panel_during_recording() {
  echo "Scenario (c): panel toggles during a video recording"
  local t0; t0=$(date +%s)
  local baseline; baseline=$(count_records "video")
  info "Starting video capture; select a small region when the overlay appears."
  send_key "$VIDEO_KEYSTROKE"
  sleep 5
  # The recording indicator window is present throughout, so it cancels out of
  # the before/during/after delta; only the clipboard panel changes the count.
  local before; before=$(drobu_window_count)
  info "Opening panel via hotkey (windows before: $before)."
  send_key "$PANEL_KEYSTROKE"
  sleep 2
  local during; during=$(drobu_window_count)
  [ "$during" -gt "$before" ] || fail "(c) panel did not open during recording (windows $before -> $during)"
  info "Closing panel via hotkey."
  send_key "$PANEL_KEYSTROKE"
  sleep 2
  local after; after=$(drobu_window_count)
  [ "$after" -le "$before" ] || fail "(c) panel did not close (windows $before -> $during -> $after)"
  info "Stopping recording with Esc."
  send_key "$ESC_KEYSTROKE"
  local elapsed; elapsed=$(poll_for_new_record "video" "$baseline" "$t0" "$POLL_TIMEOUT")
  [ "$elapsed" -ge 0 ] || fail "(c) no new video record saved after panel toggle + Esc"
  info "PASS (c): panel opened ($before->$during) and closed (->$after); recording saved ${elapsed}s after start"
}

# --- Main ---

check_prereqs
echo
scenario_video_esc; echo
scenario_gif_esc; echo
scenario_panel_during_recording; echo
echo "All scenarios passed. Note: test captures were written to your clipboard history — delete them from the panel if unwanted."
