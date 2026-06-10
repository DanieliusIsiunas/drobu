# SMAppService / Background Task Management Gotchas

Learned shipping the privileged daemon (PR #31) and the display-off follow-up
(protocol v2). All observed live on macOS 26.3, Apple Silicon.

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
