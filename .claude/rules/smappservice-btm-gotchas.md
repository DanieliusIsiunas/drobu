# SMAppService / Background Task Management Gotchas

Learned shipping the privileged daemon (PR #31) and the display-off follow-up
(protocol v2). All observed live on macOS 26.3, Apple Silicon.

## A binary swap does NOT make a running daemon unreachable (the "zombie" model was wrong)

Tested empirically 2026-06-10: `./build.sh --install` over a running daemon —
even with a genuinely different on-disk cdhash (forced via a `daemonBuildVersion`
bump) — does **not** reproduce the "stale daemon at handshake (unreachable)"
field failure. The handshake succeeds straight through, every time. Reason:
the daemon runs `dispatchMain()` and never exits, so it has **no KeepAlive**,
only `RunAtLoad` + `MachServices`. A running Unix process keeps its **original
inode mapped** after the file is overwritten, so its code-signature stays valid
against its own loaded bytes regardless of what is written to disk — the
client's identity pin (identifier + team + Apple anchor, NOT cdhash) still
passes. There is no persistent "replaced-binary zombie."

**Implication:** the real field "unreachable" right after a Sparkle update is a
**transient** state — during bundle replacement launchd briefly has no provider
for the mach service (the job reloads against the swapped bundle), and a fresh
client connection in that window fails. It resolves on its own; the correct
primary fix is a **bounded handshake retry**, not the heavy
unregister/register reinstall (PRs #33/#34 were built on the wrong root-cause
model — not harmful, but heavier than needed and themselves only validatable
against a real update).

**How to actually reproduce / test the unreachable path locally:** force the
daemon genuinely down while it stays registered (`sudo launchctl kill SIGKILL
system/com.danielius.ClipboardHistory.daemon`, or `sudo kill -9 <pid>`) and
immediately activate Closed Lid. If MachServices on-demand relaunch fires, the
client reaches a fresh daemon (self-recovery, no heal needed); if not, the
unreachable→retry/reinstall path engages and can be watched in app.log. The
only fully faithful test of the post-update window is a genuine Sparkle update.

**Process lesson:** don't claim an update-path fix is validated by a method
that doesn't actually reproduce the failure. Confirm the repro triggers the bug
*before* trusting that a green run proves the fix.

## Replacing the app bundle does NOT restart a running daemon

`build.sh --install` (or a Sparkle update) replaces the binary on disk, but
launchd keeps the **old daemon process** running — `BundleProgram` is resolved
at spawn time, not monitored. A daemon that never exits (`dispatchMain()`)
serves the mach service with stale code until reboot or an explicit bounce.

Consequences:
- After any app update that bumps the XPC protocol version, the client
  handshakes against the OLD protocol. `register()` is a **no-op** on an
  already-registered service — it never bounces the process, so "re-register
  on mismatch" remediation loops forever.
- The working bounce is `unregister()` (BTM terminates the process) followed by
  `register()` — implemented as `DaemonRegistrar.reinstall()`, driven by the
  protocol-mismatch path in `ClosedLidService.start()`.
- Manual dev-machine equivalent: `sudo launchctl kickstart -k
  system/<daemon-label>`.

## unregister() is asynchronous under the hood — immediate re-register hits EPERM

`SMAppService.unregister()` returns (and `status` even reads `.notRegistered`)
**before** `backgroundtaskmanagementd` finishes tearing down the record. A
`register()` issued in that window fails with:

```
SMAppServiceErrorDomain Code=1 "Operation not permitted"
```

- `status` is NOT a reliable settle signal (it reads `.notRegistered` while the
  teardown is still in flight) — poll-status-then-register does not fix this.
- Fix: retry `register()` with backoff (300ms doubling, 4 attempts — see
  `DaemonRegistrar.reinstall()`). Only retry `.failed`; a `.requiresApproval`
  result is a user decision, not a race — return it immediately.

## A replaced-binary zombie fails the code-sign pin as "unavailable", not "mismatch"

The third stale-daemon shape (observed live on the 1.4.1→1.5 Sparkle update):
the old daemon process keeps running after the bundle swap, and validating a
process whose backing executable was **replaced on disk** fails the client's
`setCodeSigningRequirement` pin — the connection is refused **before any XPC
message round-trips**, so the failure surfaces as *unreachable* (error handler,
no reply), never as a protocol mismatch. Symptoms: registration reads
`.enabled` ("Approved" in Settings), yet every call nils out. A mismatch-only
self-heal misses this entirely — treat **approved-but-unreachable at
handshake** as a stale daemon too and bounce it (`reinstall()`), exactly like a
mismatch. Manual recovery: Settings → Remove Helper, then re-activate.

## A cached NSXPCConnection does not survive an unregister/register cycle

Observed live on the 1.5→1.5.1 update: the reinstall bounce succeeded (zombie
killed, register → `.enabled`, fresh daemon running via RunAtLoad), yet the
re-handshake on the **cached** `NSXPCConnection` still returned nil. A
connection created against the old service instance — especially one whose
`setCodeSigningRequirement` already failed against the zombie — does not
reliably re-attach after the service is unregistered/re-registered underneath
it, and the invalidation that would clear a connection cache may never fire in
this sequence. **After any daemon reinstall, explicitly `invalidate()` and drop
the cached connection** so the next call builds a fresh one
(`DaemonClient.resetConnection()`). Also allow a settle retry on the
re-handshake: the fresh daemon runs `startUp()` (file sweep + reconciliation
with `pmset` subprocess reads) *before* resuming its listener.

## The Login Items toggle UI can lag reality

System Settings can show the daemon's background toggle ON while the
registration was just removed (or vice versa) — the pane caches. Never debug
registration state from the Settings UI; use `SMAppService.status` (mapped in
`DaemonRegistrar`) or `sfltool dumpbtm` (sudo) as ground truth.

## Route errors by what the user can act on

A protocol mismatch / reinstall race must NOT show the "approve the helper"
guidance — the helper is already approved and the toggle fixes nothing. Reserve
approval guidance for statuses that genuinely need the toggle
(`requiresApproval` after a reinstall); transient races get a "try again in a
moment" visible failure. Misrouted guidance sends users hunting through System
Settings for a problem that isn't there (live confusion during display-off
verification, 2026-06-10).
