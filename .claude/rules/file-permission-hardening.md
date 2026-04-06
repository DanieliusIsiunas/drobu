# File Permission Hardening

## Principle: Control permissions at creation, not after

When a library creates files internally (SQLite WAL/SHM, AVFoundation temp files, any C library calling `open()`), you cannot secure them with post-hoc `setAttributes` because:

1. **You don't know all the files** — SQLite creates `-wal` and `-shm` lazily on first write, not when you open the database
2. **TOCTOU race** — between file creation (world-readable) and your chmod call, another process can read the file
3. **You miss future files** — library updates may create new auxiliary files you don't know about

## Correct approach: `umask` wrapper

Set a restrictive umask before calling the library, restore it after:

```swift
let oldMask = umask(0o077)   // all new files: owner-only (0o600 for files, 0o700 for dirs)
defer { umask(oldMask) }

let pool = try DatabasePool(path: path)  // .sqlite, -wal, -shm all inherit 0o600
```

## When to apply

- Any database initialization (GRDB, SQLite, Core Data)
- Any file export (AVAssetExportSession, CGImageDestination)
- Any temp file creation via a library you don't control
- Anywhere the created file could contain user data

## When NOT needed

- Files you create yourself with `Data.write(to:)` or `FileManager.createFile()` — set permissions directly via attributes
- Directories — set permissions in the `createDirectory(attributes:)` call
- Files in a directory that's already `0o700` — the directory permission prevents access, but defense-in-depth says still use umask for the files
