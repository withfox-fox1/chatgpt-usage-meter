import Testing
import Foundation
@testable import ChatGPTUsageCore

// UsageStore persists to UserDefaults.standard. Serialized because all
// tests share the same UserDefaults keys.
@Suite(.serialized)
struct UsageStoreTests {
    init() {
        UserDefaults.standard.removeObject(forKey: "ChatGPTUsageCore.snapshot")
        UserDefaults.standard.removeObject(forKey: "ChatGPTUsageCore.history")
    }

    @Test func saveAndLoadSnapshotRoundTrips() {
        let store = UsageStore()
        let snapshot = UsageSnapshot(
            session: UsageLimit(kind: "session", percent: 42, resetsAt: Date(), isActive: true),
            weekly: nil,
            fetchedAt: Date(),
            isStale: false,
            needsLogin: false
        )

        store.save(snapshot: snapshot)
        let loaded = store.loadSnapshot()

        #expect(loaded == snapshot)
    }

    @Test func loadSnapshotReturnsNilWhenNothingSaved() {
        let store = UsageStore()
        #expect(store.loadSnapshot() == nil)
    }

    @Test func appendHistoryKeepsOldestFirstAndTrims() {
        let store = UsageStore()
        let base = Date()

        for i in 0..<5 {
            let point = HistoryPoint(timestamp: base.addingTimeInterval(TimeInterval(i)), sessionPercent: i, weeklyPercent: nil)
            store.appendHistory(point, maxPoints: 3)
        }

        let history = store.loadHistory()
        #expect(history.count == 3)
        #expect(history.map { $0.sessionPercent } == [2, 3, 4])
        // Oldest first.
        #expect(history[0].timestamp < history[1].timestamp)
        #expect(history[1].timestamp < history[2].timestamp)
    }
}
