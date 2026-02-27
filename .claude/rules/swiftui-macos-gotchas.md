# SwiftUI macOS Gotchas

## Settings Scene

The `Settings` scene switches activation policy: `.accessory` → `.regular` (open) → `.accessory` (close).

- **Buttons don't receive clicks** inside grouped `Form`. Use `Text` + `.onTapGesture` instead of `Button`.
- **`NSApp.delegate as? AppDelegate` returns nil**. Access shared resources directly (e.g. `AppDatabase()`).
- **`.alert` / `.confirmationDialog` actions silently never fire**. Use `NSAlert.beginSheetModal(for: NSApp.keyWindow!)`.

## NSPanel + SwiftUI

- `onAppear`/`onDisappear` don't reliably fire for SwiftUI views in `NSHostingView`. Recreate the panel each time.
- Use `WeakFloatingPanel` wrapper for environment keys to avoid retain cycles.
- `animationBehavior = .none` makes `close()` instant. Don't use `alphaValue = 0` with `NSVisualEffectView`.
