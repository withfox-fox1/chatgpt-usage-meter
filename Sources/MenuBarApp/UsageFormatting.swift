import Foundation

// MARK: - 日本語の日時表示ヘルパー

enum UsageFormatting {
    private static let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    /// "9/9(水) 9:00にリセット" のような絶対時刻表記。週間制限のリセット表示に使う。
    static func absoluteResetString(_ date: Date, calendar: Calendar = .current) -> String {
        "\(absoluteDateTimeString(date, calendar: calendar))にリセット"
    }

    /// "9/9(水) 9:00" 部分のみ(ラベルなし)。
    static func absoluteDateTimeString(_ date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let weekdayIndex = max(0, min(weekdaySymbols.count - 1, (comps.weekday ?? 1) - 1))
        let weekday = weekdaySymbols[weekdayIndex]
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        return String(format: "%d/%d(%@) %d:%02d", month, day, weekday, hour, minute)
    }

    /// "4時間4分後にリセット" のような相対時刻表記。5時間セッションのリセット表示に使う。
    static func relativeResetString(_ date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 {
            return "まもなくリセット"
        }
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, 0):
            return "まもなくリセット"
        case (0, let m):
            return "\(m)分後にリセット"
        case (let h, 0):
            return "\(h)時間後にリセット"
        case (let h, let m):
            return "\(h)時間\(m)分後にリセット"
        }
    }

    /// "たった今" / "3分前" / "2時間前" のような相対更新時刻表記。
    static func relativeUpdateString(_ date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        let minutes = Int(interval / 60)
        if minutes < 1 { return "たった今" }
        if minutes < 60 { return "\(minutes)分前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)時間前" }
        let days = hours / 24
        return "\(days)日前"
    }
}
