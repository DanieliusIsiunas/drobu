import Foundation

/// Remembers the image-markup colour across editor sessions (red by default).
enum MarkupDefaults {
    static let colorKey = "imageMarkupColor"

    static func loadColor(from defaults: UserDefaults = .standard) -> MarkupColor {
        defaults.string(forKey: colorKey).flatMap(MarkupColor.init(rawValue:)) ?? .red
    }

    static func saveColor(_ color: MarkupColor, to defaults: UserDefaults = .standard) {
        defaults.set(color.rawValue, forKey: colorKey)
    }
}
