import Foundation

/// Persists the latest `UsageSnapshot` and a bounded history of usage
/// samples in the app's own `UserDefaults.standard` (no App Group, so the
/// app can be signed without a provisioning profile).
public final class UsageStore {
    private let snapshotKey: String
    private let historyKey: String

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameter namespace: Separates the stored values per account. `nil`
    ///   uses the original (pre multi-account) keys so existing data is kept.
    public init(namespace: String? = nil) {
        self.defaults = .standard
        let suffix = namespace.map { ".\($0)" } ?? ""
        self.snapshotKey = "ChatGPTUsageCore.snapshot" + suffix
        self.historyKey = "ChatGPTUsageCore.history" + suffix
    }

    /// Removes everything this store has saved (used when an account is deleted).
    public func clear() {
        defaults.removeObject(forKey: snapshotKey)
        defaults.removeObject(forKey: historyKey)
    }

    public func save(snapshot: UsageSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public func loadSnapshot() -> UsageSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    /// Appends `point`, keeps history sorted oldest-first, and trims from the
    /// front once it exceeds `maxPoints`.
    public func appendHistory(_ point: HistoryPoint, maxPoints: Int) {
        var history = loadHistory()
        history.append(point)
        history.sort { $0.timestamp < $1.timestamp }
        if maxPoints >= 0, history.count > maxPoints {
            history.removeFirst(history.count - maxPoints)
        }
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: historyKey)
    }

    public func loadHistory() -> [HistoryPoint] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? decoder.decode([HistoryPoint].self, from: data)) ?? []
    }
}
