import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Fires a local notification the moment usage crosses one of `thresholds`
/// from below (edge-triggered): staying above a threshold across multiple
/// `evaluate` calls only notifies once, dropping back below it and crossing
/// again notifies again, and a rollover (the window's `resetsAt` changing)
/// always resets the tracked state so the new period starts fresh.
public final class NotificationManager {
    private let thresholds: [Int]
    private let defaults: UserDefaults
    private let notify: (_ label: String, _ percent: Int, _ threshold: Int) -> Void

    public init(thresholds: [Int] = [80, 95]) {
        self.thresholds = thresholds.sorted()
        self.defaults = .standard
        self.notify = NotificationManager.postUserNotification
    }

    /// Test/internal seam: lets tests inject an isolated UserDefaults suite
    /// and capture notifications instead of touching UNUserNotificationCenter.
    init(thresholds: [Int] = [80, 95], defaults: UserDefaults, notify: @escaping (_ label: String, _ percent: Int, _ threshold: Int) -> Void) {
        self.thresholds = thresholds.sorted()
        self.defaults = defaults
        self.notify = notify
    }

    public func evaluate(previous: UsageSnapshot?, current: UsageSnapshot) {
        evaluateMetric(
            metric: "session",
            label: "5時間制限",
            previousLimit: previous?.session,
            currentLimit: current.session
        )
        evaluateMetric(
            metric: "weekly",
            label: "週間",
            previousLimit: previous?.weekly,
            currentLimit: current.weekly
        )
    }

    private func evaluateMetric(metric: String, label: String, previousLimit: UsageLimit?, currentLimit: UsageLimit?) {
        guard let currentLimit else { return }

        let levelKey = Self.levelKey(metric)
        let resetsAtKey = Self.resetsAtKey(metric)

        let storedResetsAt = defaults.object(forKey: resetsAtKey) as? Double
        let currentResetsAt = currentLimit.resetsAt.timeIntervalSince1970

        let rolledOver: Bool
        if let previousLimit {
            rolledOver = previousLimit.resetsAt != currentLimit.resetsAt
        } else if let storedResetsAt {
            rolledOver = abs(storedResetsAt - currentResetsAt) > 1
        } else {
            rolledOver = false
        }

        let previousLevel: Int
        if rolledOver {
            previousLevel = 0
        } else if let previousLimit {
            previousLevel = level(forPercent: previousLimit.percent)
        } else {
            previousLevel = defaults.object(forKey: levelKey) as? Int ?? 0
        }

        let currentLevel = level(forPercent: currentLimit.percent)

        if currentLevel > previousLevel {
            let crossedThreshold = thresholds[currentLevel - 1]
            notify(label, currentLimit.percent, crossedThreshold)
        }

        defaults.set(currentLevel, forKey: levelKey)
        defaults.set(currentResetsAt, forKey: resetsAtKey)
    }

    /// Number of thresholds at or below `percent` (0 = below all thresholds).
    private func level(forPercent percent: Int) -> Int {
        var level = 0
        for (index, threshold) in thresholds.enumerated() where percent >= threshold {
            level = index + 1
        }
        return level
    }

    private static func levelKey(_ metric: String) -> String {
        "ChatGPTUsageCore.notif.\(metric).level"
    }

    private static func resetsAtKey(_ metric: String) -> String {
        "ChatGPTUsageCore.notif.\(metric).resetsAt"
    }

    private static func postUserNotification(label: String, percent: Int, threshold: Int) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "ChatGPT使用量メーター"
        content.body = "\(label)の使用率が\(threshold)%を超えました(現在\(percent)%)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        #endif
    }
}
