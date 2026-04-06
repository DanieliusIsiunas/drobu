---
title: "refactor: Pre-launch hardening — DB permissions, entitlement docs, force unwrap safety"
type: refactor
date: 2026-04-06
---

# Pre-Launch Hardening

Three categories of defensive fixes before public release. No new features, no behavior changes — just tightening existing code.

## 1. SQLite DB File Permissions

### Problem

`AppDatabase.openPool()` creates the SQLite file via `DatabasePool(path:)`. GRDB inherits the process umask (typically `0o022`), so the file is created as `0o644` (world-readable). The directory is already `0o700`, but if directory permissions are ever loosened (or on a multi-user system), clipboard history is readable by other users.

### Fix

Set `0o600` on the database file (and WAL/SHM) after pool creation.

**`Sources/Database/AppDatabase.swift`** — in `openPool(at:)`, after both the happy path and the corruption-recovery path return a pool:

```swift
private static func openPool(at path: String) throws -> DatabasePool {
    let pool: DatabasePool
    do {
        pool = try DatabasePool(path: path)
    } catch {
        Log.error("AppDatabase: corruption detected, recreating: \(error)")
        // ... existing cleanup ...
        pool = try DatabasePool(path: path)
    }
    // Restrict file permissions to owner-only
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path + suffix
        )
    }
    return pool
}
```

`try?` is acceptable here because:
- The `-wal` and `-shm` files may not exist yet (created on first write)
- Failure to set permissions is non-fatal (directory is already `0o700`)
- Logging would be noise on every launch for files that don't exist yet

### Acceptance Criteria

- [x] After launch, `ls -la ~/Library/Application\ Support/ClipboardHistory/clipboard.sqlite` shows `-rw-------` (`0o600`)

---

## 2. Document Entitlement Necessity

### Problem

`disable-library-validation` in `Drobu.entitlements` looks like a security concern but is required. Self-signed certificates lack a team identifier, so macOS library validation rejects Sparkle.framework even though it's signed with the same cert.

This is already documented in `.claude/rules/sparkle-macos-gotchas.md` but not in the entitlements file itself, where a reviewer would look.

### Fix

Add XML comments to the entitlements file explaining why each entitlement exists and when it can be removed.

**`Sources/Drobu.entitlements`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Required for simulating Cmd+V paste into the frontmost app via CGEvent -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <!-- Required because self-signed certs lack a team identifier, so library
         validation rejects Sparkle.framework even when signed with the same cert.
         Remove this once the app is signed with an Apple Developer ID certificate. -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

### Acceptance Criteria

- [x] Entitlements file contains comments explaining both entitlements
- [x] App still launches and Sparkle loads correctly after rebuild

---

## 3. Replace Force Unwraps with Safe Patterns

### Problem

13 locations use `!`, `as!`, or `[0]` on runtime data. All are implicitly safe (guarded by upstream checks), but they're brittle — a future refactor could remove the guard and leave a crash. Replace with idiomatic Swift safe access.

### Fixes (by file)

#### `Sources/Services/ScreenCaptureService.swift:236`

```swift
// Before:
delay = frames.last!.delay
// After:
delay = frames.last?.delay ?? defaultDelay
```

#### `Sources/Services/ScreenCaptureService.swift:146-148`

```swift
// Before:
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
guard let targetDisplay = availableContent.displays.first(where: {
    displayID != nil ? $0.displayID == displayID! : true
}) else {

// After:
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
guard let targetDisplay = availableContent.displays.first(where: {
    if let displayID { return $0.displayID == displayID }
    return true
}) else {
```

#### `Sources/Services/VideoCaptureService.swift:236-239` — same `displayID!` pattern, same fix

#### `Sources/Services/ClosedLidService.swift:13`

```swift
// Before:
let obj = Unmanaged<ClosedLidService>.fromOpaque(refcon!).takeUnretainedValue()
// After:
guard let refcon else { return }
let obj = Unmanaged<ClosedLidService>.fromOpaque(refcon).takeUnretainedValue()
```

#### `Sources/Views/LargePreviewPanel.swift:280` (makeNSView)

```swift
// Before:
let textView = scrollView.documentView as! NSTextView
// After:
guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
```

#### `Sources/Views/LargePreviewPanel.swift:299` (updateNSView)

```swift
// Before:
let textView = scrollView.documentView as! NSTextView
// After:
guard let textView = scrollView.documentView as? NSTextView else { return }
```

#### `Sources/Models/ClipboardRecord.swift:33`

```swift
// Before:
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
// After:
(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
```

Note: This is a computed property returning a URL, can't throw. Fallback to temp directory is safe — the directory creation call downstream will handle it.

#### `Sources/App/AppDelegate.swift:532`

```swift
// Before:
NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
// After:
if let fallback = URL(string: "x-apple.systempreferences:") {
    NSWorkspace.shared.open(fallback)
}
```

#### `Sources/Views/FloatingPanel.swift:244` — guarded by `records.count == 1`

```swift
// Before:
pasteItem(records[0])
// After:
if let first = records.first { pasteItem(first) }
```

#### `Sources/Views/PanelView.swift:780` — guarded by `opts.count == 1`

```swift
// Before:
await cmd.execute(option: opts[0])
// After:
if let opt = opts.first { await cmd.execute(option: opt) }
```

#### `Sources/Views/PanelView.swift:877`

```swift
// Before:
let screen = parentPanel.screen ?? NSScreen.main ?? NSScreen.screens[0]
// After:
guard let screen = parentPanel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
```

#### `Sources/Views/PanelView.swift:1109` — guarded by `!selected.isEmpty` + `selected.count == 1`

```swift
// Before:
panel?.pasteItem(selected[0])
// After:
if let first = selected.first { panel?.pasteItem(first) }
```

#### `Sources/Views/ClipboardRowView.swift:136` — guarded by `paths.count == 1`

```swift
// Before:
return "File: \(URL(fileURLWithPath: String(paths[0])).lastPathComponent)"
// After:
guard let first = paths.first else { return "File" }
return "File: \(URL(fileURLWithPath: String(first)).lastPathComponent)"
```

#### `Sources/Views/PreviewPanel.swift:224` — guarded by `paths.count == 1`

```swift
// Before:
let url = URL(fileURLWithPath: String(paths[0]))
// After:
guard let first = paths.first else { return }
let url = URL(fileURLWithPath: String(first))
```

### Acceptance Criteria

- [x] `grep -rn '\.last!' Sources/` returns zero results
- [x] `grep -rn 'as! NS' Sources/` returns zero results (for NSTextView casts)
- [x] `grep -rn 'refcon!' Sources/` returns zero results
- [x] `grep -rn 'displayID!' Sources/` returns zero results
- [x] App builds clean with no warnings
- [x] App launches and basic clipboard capture + paste works
