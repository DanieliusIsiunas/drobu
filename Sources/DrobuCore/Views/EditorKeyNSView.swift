import AppKit

/// First-responder NSView owning the inline editors' shared keyboard contract:
/// Cmd+Return (keyCode 36) saves, Esc (keyCode 53) discards.
///
/// `GIFPlayerNSView`, `VideoTrimNSView`, and the image editor's key view all derive
/// from (or use) this class so the key binding lives in exactly one place.
class EditorKeyNSView: NSView {
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Return → save
        if event.keyCode == 36 && flags.contains(.command) {
            onSave?()
            return
        }

        // Escape → discard
        if event.keyCode == 53 {
            onDiscard?()
            return
        }

        super.keyDown(with: event)
    }
}
