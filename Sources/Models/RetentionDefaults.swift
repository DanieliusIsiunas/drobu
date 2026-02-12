import Foundation

/// UserDefaults storage for retention policy settings
enum RetentionDefaults {
    private static let retentionDaysKey = "retentionDays"
    private static let maxItemCountKey = "maxItemCount"

    /// Default retention period in days
    static let defaultRetentionDays = 30

    /// Default maximum item count
    static let defaultMaxItemCount = 5000

    /// Save retention settings
    static func save(retentionDays: Int, maxItemCount: Int) {
        UserDefaults.standard.set(retentionDays, forKey: retentionDaysKey)
        UserDefaults.standard.set(maxItemCount, forKey: maxItemCountKey)
        NotificationCenter.default.post(name: .retentionSettingsDidChange, object: nil)
    }

    /// Load retention days (returns default if not set)
    static func loadRetentionDays() -> Int {
        let value = UserDefaults.standard.integer(forKey: retentionDaysKey)
        return value > 0 ? value : defaultRetentionDays
    }

    /// Load max item count (returns default if not set)
    static func loadMaxItemCount() -> Int {
        let value = UserDefaults.standard.integer(forKey: maxItemCountKey)
        return value > 0 ? value : defaultMaxItemCount
    }
}

// MARK: - Notification

extension Notification.Name {
    static let retentionSettingsDidChange = Notification.Name("retentionSettingsDidChange")
}
