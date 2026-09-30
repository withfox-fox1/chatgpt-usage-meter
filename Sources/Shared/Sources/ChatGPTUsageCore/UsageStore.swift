import Foundation

/// Persists the latest `UsageSnapshot` and a bounded history of usage
/// samples in the app's own `UserDefaults.standard` (no App Group, so the
/// app can be signed without a provisioning profile).
public final class UsageStore {
    private static let snapshotKey = "ChatGPTUsageCore.snapshot"
    private static let historyKey = "ChatGPTUsageCore.history"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        self.defaults = .standard
    }

    public func save(snapshot: UsageSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Self.snapshotKey)
    }

    public func loadSnapshot() -> UsageSnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
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
        defaults.set(data, forKey: Self.historyKey)
    }

    public func loadHistory() -> [HistoryPoint] {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [] }
        return (try? decoder.decode([HistoryPoint].self, from: data)) ?? []
    }
}
