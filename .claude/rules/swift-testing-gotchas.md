# Swift Testing / SwiftPM Gotchas

## Tests sharing a singleton's real side-effect file pollute production state

`Log` writes to `~/Library/Application Support/ClipboardHistory/app.log`. Tests
that construct real services (e.g. `ClosedLidService`) log through the same
`Log` singleton, so fixture output — `StubError`, the tests' 2001-dated
`fixedNow` deadlines, deliberately-exercised failure paths like "activation
refused" — lands in the **shared production log**. This nearly derailed a live
debugging session: the fake "daemon unreachable — activation refused" lines
from a `swift test` run looked exactly like a real field failure.

Fix: detect the test runtime in the singleton and suppress the real side
effect (`Log.isRunningInTests` → `fileHandle` returns nil). Applies to any
singleton with a real filesystem/network/keychain side effect, not just `Log`.

## Detecting the `swift test` runtime — XCTest signals DO NOT fire for Swift Testing under SwiftPM

The obvious checks are wrong for this stack. Empirically probed on the Xcode
26 toolchain, a `swift test` run of a **Swift Testing** target (`import Testing`,
no XCTest) has:

- `XCTestConfigurationFilePath` / `XCTestBundlePath` / `XCTestSessionIdentifier`
  — **all unset** (those are Xcode/XCTest-runner vars).
- `NSClassFromString("XCTestCase")` — **nil** (XCTest isn't linked).
- `processName` — **`swiftpm-testing-helper`** (NOT `xctest`).
- `arguments[0]` — `…/usr/libexec/swift/pm/swiftpm-testing-helper`.

So the reliable signal for SwiftPM Swift Testing is the **host process name**
`swiftpm-testing-helper` (or `xctest` for the XCTest tool). Keep the XCTest
env-var / class checks too so Xcode-hosted runs are still caught. Verify any
such guard EMPIRICALLY — assert `isRunningInTests` in a test (fails loudly if a
toolchain changes the fingerprint) and confirm the side-effect file's mtime is
unchanged across a full `swift test`. Guessing the signal cost one wrong
iteration here; the probe (print processName/arg0/env) settled it in one run.

## Never name an enum case `none` — `= .none` silently means `Optional.none`

A general Swift trap, but it bites hardest in test doubles, because that is where
an enum most often ends up stored in an Optional.

`UnlockState` originally had a `case none` ("no paid entitlement"). A test double
held a `var pendingState: UnlockState?` to model a conformer mutating state, and
the test set it with the obvious spelling:

```swift
fake.pendingState = .none      // looks like UnlockState.none
```

On an `Optional<UnlockState>`, `.none` resolves to **`Optional.none` — i.e. `nil`**,
not the enum's own case. The property was set to nil, the double's `if let` guard
never fired, and the test asserted against a state that was never applied. It
compiled, ran, and reported a plain expectation failure with no hint of the cause.

Worse is the inverse: had the assertion happened to match anyway, the test would
have passed **while exercising nothing** — a green test pinning no behaviour.

Two rules:

- **Do not name an enum case `none`** when the type could plausibly be held in an
  Optional. Pick a domain word: `.unlicensed`, `.absent`, `.unset`. (`UnlockState`
  was renamed `none` → `unlicensed` for exactly this reason.)
- Where a `none`-named case already exists and you must compare or assign, **fully
  qualify it** — `UnlockState.none`, never the leading-dot shorthand — so the
  ambiguity cannot resolve the wrong way.

Related: this is why a new test should be **mutation-checked** before you trust
it. Break the production line it claims to pin and confirm that exact test fails.
Both of these defects (a test wired to nil, and a test that passes without
exercising the guard) survive a green run and die instantly under that check.
