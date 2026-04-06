import AppKit
import Carbon
import HotKey
import SwiftUI

extension Notification.Name {
    static let hotkeyDidChange = Notification.Name("hotkeyDidChange")
}

// MARK: - UserDefaults key (shared between AppDelegate and recorder)

enum HotkeyDefaults {
    static let key = "globalHotkey"

    static func save(_ combo: KeyCombo?) {
        if let combo {
            UserDefaults.standard.set(combo.dictionary, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)
    }

    static func load() -> KeyCombo {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let combo = KeyCombo(dictionary: dict) else {
            return KeyCombo(key: .v, modifiers: [.command, .shift])
        }
        return combo
    }
}

// MARK: - AppKit NSView that captures key combos

final class HotkeyRecorderNSView: NSView {
    var keyCombo: KeyCombo? {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
    }
    var isRecording = false {
        didSet { needsDisplay = true }
    }
    var onChange: ((KeyCombo?) -> Void)?
    var saveAction: (KeyCombo?) -> Void = { HotkeyDefaults.save($0) }
    var accessibilityLabelText: String = "Hotkey" {
        didSet { setAccessibilityLabel(accessibilityLabelText) }
    }

    override var acceptsFirstResponder: Bool { true }

    private func updateAccessibilityValue() {
        if let combo = keyCombo {
            setAccessibilityValue(combo.description)
        } else {
            setAccessibilityValue("None")
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        path.fill()

        if isRecording {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let text: String
        if isRecording {
            text = "Press shortcut\u{2026}"
        } else if let combo = keyCombo {
            text = combo.description
        } else {
            text = "None"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .medium : .regular),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attrString.draw(in: textRect)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            isRecording = false
        } else {
            isRecording = true
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)

        // Escape cancels recording
        if keyCode == UInt32(kVK_Escape) {
            isRecording = false
            return
        }

        // Delete clears — reset to nil (caller decides default)
        if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) {
            keyCombo = nil
            isRecording = false
            saveAction(nil)
            onChange?(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])

        // Require at least Cmd, Ctrl, or Option (not just Shift alone)
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else {
            return
        }

        let combo = KeyCombo(carbonKeyCode: keyCode, carbonModifiers: modifiers.carbonFlags)
        keyCombo = combo
        isRecording = false
        saveAction(combo)
        onChange?(combo)
    }

    override func flagsChanged(with event: NSEvent) {
        if !isRecording {
            super.flagsChanged(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }
}

// MARK: - SwiftUI wrapper

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCombo: KeyCombo?
    var saveAction: @MainActor (KeyCombo?) -> Void = { HotkeyDefaults.save($0) }
    var accessibilityLabelText: String = "Hotkey"

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.keyCombo = keyCombo
        view.saveAction = saveAction
        view.onChange = { newCombo in
            keyCombo = newCombo
        }
        view.setAccessibilityRole(.button)
        view.accessibilityLabelText = accessibilityLabelText
        view.setAccessibilityHelp("Click to record a new keyboard shortcut")
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.keyCombo = keyCombo
        nsView.saveAction = saveAction
        nsView.accessibilityLabelText = accessibilityLabelText
    }
}
