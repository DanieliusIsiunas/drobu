import AppKit
import SwiftUI

// MARK: - Custom NSTextView that intercepts Cmd+Return

fileprivate final class EditableNSTextView: NSTextView {
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onCleanup: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Return → save
        if event.keyCode == 36 && flags.contains(.command) {
            onSave?()
            return
        }

        // Arrow up at position 0 with no selection → cleanup
        // Note: arrow keys have .numericPad and .function flags by default on macOS
        let userFlags = flags.subtracting([.numericPad, .function])
        if event.keyCode == 126
            && userFlags.isEmpty
            && selectedRange().location == 0
            && selectedRange().length == 0 {
            onCleanup?()
            return
        }

        super.keyDown(with: event)
    }
}

// MARK: - NSViewRepresentable (always editable, created only in edit mode)

struct EditableTextView: NSViewRepresentable {
    @Binding var text: String
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onCleanup: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = EditableNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSave = onSave
        textView.onDiscard = onDiscard
        textView.onCleanup = onCleanup
        textView.setAccessibilityLabel("Text editor")
        textView.setAccessibilityHelp("Command Return to save, Escape to discard")

        // Set initial text without triggering textDidChange
        context.coordinator.suppressTextChange = true
        textView.string = text
        context.coordinator.suppressTextChange = false

        scrollView.documentView = textView

        // Acquire focus after layout
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditableNSTextView else { return }
        // Keep callbacks current
        textView.onSave = onSave
        textView.onDiscard = onDiscard
        textView.onCleanup = onCleanup

        // Sync text when binding changes programmatically (e.g. cleanup)
        if textView.string != text {
            context.coordinator.suppressTextChange = true
            textView.string = text
            context.coordinator.suppressTextChange = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextView
        var suppressTextChange = false

        init(_ parent: EditableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextChange else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Escape → discard
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onDiscard?()
                return true
            }
            return false
        }
    }
}
