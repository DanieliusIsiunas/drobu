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

    /// Cmd+Return (any other modifiers allowed).
    static func isSaveKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    static func isDiscardKey(_ event: NSEvent) -> Bool {
        event.keyCode == 53
    }

    override func keyDown(with event: NSEvent) {
        if Self.isSaveKey(event) {
            onSave?()
            return
        }

        if Self.isDiscardKey(event) {
            onDiscard?()
            return
        }

        super.keyDown(with: event)
    }
}
