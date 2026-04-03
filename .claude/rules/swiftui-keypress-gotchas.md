# SwiftUI KeyPress Gotchas (macOS)

## Arrow keys have `.numericPad` modifier

On macOS, arrow key events include `.numericPad` (and sometimes `.function`) in `press.modifiers`. This means:

- `press.modifiers.isEmpty` → **always false** for arrow keys
- `press.modifiers == .command` → **false** for Cmd+Arrow (actual: `[.command, .numericPad]`)

**Do this** (match the key, use `.contains` for intentional modifiers):
```swift
if press.key == .rightArrow {
    if press.modifiers.contains(.command) { /* Cmd+Right */ }
    else { /* plain Right */ }
}
```

**Don't do this** (will silently reject all arrow events):
```swift
guard press.modifiers.isEmpty else { return .ignored }
guard press.modifiers == .command else { return .ignored }
```

The existing `/sleep` section tab switching works because it only checks `press.key`, never `press.modifiers`.
