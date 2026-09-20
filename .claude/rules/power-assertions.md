# IOKit Power Assertion Gotchas

Learned converting Keep Awake off the `/usr/bin/caffeinate` subprocess onto
in-process IOKit assertions (v1.11.x, sandbox-readiness work). All verified live
on Apple Silicon / macOS 26 with throwaway probes, not inferred from headers.

Companion to `applesilicon-display.md` (which covers *display* power and the
privileged Closed-Lid path). This file is about the userspace assertion API.

## `IOPMAssertionSetTimeout` is NOT exposed to Swift — use `CreateWithProperties`

The obvious spelling does not compile:

```
error: cannot find 'IOPMAssertionSetTimeout' in scope
```

`IOPMAssertionCreateWithName` exists in Swift but has no timeout companion. To get
a **kernel-enforced** timeout, build the assertion from a properties dictionary:

```swift
let props: [String: Any] = [
    kIOPMAssertionTypeKey as String: type,
    kIOPMAssertionNameKey as String: reason,
    kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
    kIOPMAssertionTimeoutKey as String: duration,                     // seconds
    kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String,
]
var id = IOPMAssertionID(0)
let rc = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
```

**A timeout of `0` means "never time out", not "expire immediately."** Guard
`duration > 0` before creating, or a zero-length session holds the Mac awake
forever.

## Releasing after the kernel timeout returns `kIOReturnBadArgument` — do NOT log it as an error

powerd releases the assertion *exactly* at the timeout. Any app-side timer aimed
at the same deadline can only fire at-or-after it, so on the **healthiest** path
(a session allowed to run to completion) your `IOPMAssertionRelease` lands on an
ID the kernel already dropped and returns `0xE00002C2` (`kIOReturnBadArgument`).

Measured:

```
release at deadline-0.30s -> 0x00000000 SUCCESS
release at deadline-0.05s -> 0x00000000 SUCCESS
release at deadline+0.00s -> 0xE00002C2 FAILURE
release at deadline+1.00s -> 0xE00002C2 FAILURE
```

Treating that as an error **inverts the signal**: every well-behaved session
writes ERROR lines to `app.log`, while a session the user stopped early (which
releases live IDs) stays silent. `app.log` is step one of this project's
debugging runbook, and `.claude/rules/swift-testing-gotchas.md` already records
fake ERROR lines nearly derailing a live debugging session — so this noise is
expensive. Classify `kIOReturnBadArgument` / `kIOReturnNotFound` as
"already released" and log at debug; keep every other non-success code loud.
(`IOPMPowerAssertion.isAlreadyReleased`, unit-tested.)

Double-release is likewise harmless — it returns the same code and does nothing.

## `caffeinate -dims` is FOUR assertions, not two — and `-s` is load-bearing

Observed from a live `caffeinate -dims`:

```
PreventUserIdleSystemSleep    (-i)
PreventUserIdleDisplaySleep   (-d)
PreventSystemSleep            (-s)
PreventDiskIdle               (-m)
```

Porting only `-d` + `-i` looks equivalent and is not:

- **`PreventSystemSleep` (`-s`)** is the **AC-only** assertion that keeps the Mac
  running in dark wake through a **lid close** or demand sleep. Drop it and a user
  who starts Keep Awake on AC for a long transfer, then closes the lid, loses the
  transfer. Zero difference on battery (the assertion is inert there).
  `ClosedLidService` independently depends on it — it spawns `caffeinate -ims`,
  deliberately keeping `-s` while dropping `-d`.
- **`PreventDiskIdle` (`-m`)** is genuinely unobservable on an SSD Mac; dropping
  it is free.

Do not reason "the display is held on, so the system can't sleep anyway" — that
argues `-i` is redundant with `-d`, and says nothing about `-s`, which governs
**non-idle** sleep.

## Assertion IDs are globally monotonic, so a stale ID cannot collide

`IOPMAssertionID`s increment across the whole system (gaps appear where other
processes took one). A stale ID can therefore never alias a live assertion held
elsewhere in-process (AVPlayer's `preventsDisplaySleepDuringVideoPlayback`,
Sparkle). That is why discarding IDs after a failed release is bounded rather than
dangerous.

## Assertions die with the process — strictly better than a subprocess

A `caffeinate` child **outlives a crashed or force-quit parent** until its `-t`
elapses, leaving the Mac awake with no owner to reverse it. In-process assertions
are reaped by the kernel when the process dies, so a crash can never strand them.
(Confirmed in passing: a stray `caffeinate` holding `PreventUserIdleSystemSleep`
for minutes with no live owner is exactly this failure mode.)

Bonus: `pmset -g assertions` and Activity Monitor's "Preventing Sleep" column now
name the app (`"Drobu Keep Awake"`) instead of `"caffeinate command-line tool"` —
a real win for any user diagnosing why their Mac won't sleep.

## Wall clock vs kernel timeout can diverge (accepted)

`remainingTime` is `Date`-derived; the kernel timeout is fixed at create time. A
**backward** wall-clock jump makes the app think time remains while powerd has
already released — the badge stays lit over nothing. Nothing observes assertion
timeouts, so this is undetectable without polling. Accepted: forward jumps and
sleep/wake converge correctly, and the old `caffeinate -t` had the same shape with
a worse failure mode.
