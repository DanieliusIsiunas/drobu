# Testing Conventions

## Tests ship with features, not after

When implementing new logic in Models/, Database/, or Services/, write tests in the same commit. Do not defer testing to a follow-up. Run `swift test` before committing.

## Test infrastructure available

- `makeTestDatabase()` — temp-file DatabasePool with full migration chain
- `makeRecord(...)` — ClipboardRecord factory with sensible defaults
- `MockPasteboardItem.text/gif/image()` — pasteboard item doubles for extractRecord tests
- `@MainActor @Suite` — required for testing @MainActor-isolated services

## When to use which pattern

- **New ClipboardRecord query/mutation** → write test using `makeTestDatabase()`, assert in a `db.pool.write/read` block
- **New content type or extraction logic** → write test using `MockPasteboardItem`, call `monitor.extractRecord(from:sourceApp:sourceBundleId:)`
- **New service with state machine** → test with real dependencies if harmless, `defer { service.cleanup() }` if it spawns processes
- **New pure function** → test directly, use `@Test(arguments:)` for parameterized cases

## What not to test

- SwiftUI views and AppKit UI wiring (NSPanel, NSStatusBar)
- Apple framework internals (CryptoKit hash correctness, ImageIO parsing)
- Trivial default values or guard clauses
