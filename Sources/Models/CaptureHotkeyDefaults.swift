import Foundation
import HotKey

extension Notification.Name {
    static let captureHotkeyDidChange = Notification.Name("captureHotkeyDidChange")
}

enum CaptureHotkeyDefaults {
    static let key = "captureHotkey"

    static func save(_ combo: KeyCombo?) {
        if let combo {
            UserDefaults.standard.set(combo.dictionary, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .captureHotkeyDidChange, object: nil)
    }

    static func load() -> KeyCombo {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let combo = KeyCombo(dictionary: dict) else {
            return KeyCombo(key: .g, modifiers: [.control, .shift])
        }
        return combo
    }
}
