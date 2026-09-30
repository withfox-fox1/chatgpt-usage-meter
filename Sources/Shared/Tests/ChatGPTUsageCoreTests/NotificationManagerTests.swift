import Testing
import Foundation
@testable import ChatGPTUsageCore

struct NotificationManagerTests {
    private final class Recorder: @unchecked Sendable {
        private(set) var events: [(String, Int, Int)] = []
        func record(_ label: String, _ percent: Int, _ threshold: Int) {
            events.append((label, percent, threshold))
        }
    }

    private func makeManager(suiteName: String) -> (NotificationManager, Recorder) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let recorder = Recorder()
        let manager = NotificationManager(thresholds: [80, 95], defaults: defaults) { label, percent, threshold in
            recorder.record(label, percent, threshold)
        }
        return (manager, recorder)
    }

    private func limit(percent: Int, resetsAt: Date, kind: String = "session") -> UsageLimit {
        UsageLimit(kind: kind, percent: percent, resetsAt: resetsAt, isActive: true)
    }

    private func snapshot(sessionPercent: Int?, resetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            session: sessionPercent.map { limit(percent: $0, resetsAt: resetsAt) },
            weekly: nil,
            fetchedAt: Date(),
            isStale: false,
            needsLogin: false
        )
    }

    @Test func firesWhenCrossingThresholdFromBelow() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.crossing")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: resetsAt), current: snapshot(sessionPercent: 85, resetsAt: resetsAt))

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.1 == 85)
        #expect(recorder.events.first?.2 == 80)
    }

    @Test func doesNotRefireWhileStayingAtSameLevel() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.samelevel")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: resetsAt), current: snapshot(sessionPercent: 85, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        // Still above 80, still below 95 -> same level, should not refire.
        manager.evaluate(previous: snapshot(sessionPercent: 85, resetsAt: resetsAt), current: snapshot(sessionPercent: 88, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)
    }

    @Test func firesAgainWhenCrossingHigherThreshold() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.higher")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: resetsAt), current: snapshot(sessionPercent: 85, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        manager.evaluate(previous: snapshot(sessionPercent: 85, resetsAt: resetsAt), current: snapshot(sessionPercent: 96, resetsAt: resetsAt))
        #expect(recorder.events.count == 2)
        #expect(recorder.events.last?.2 == 95)
    }

    @Test func doesNotFireWhenDroppingBelowThreshold() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.drop")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: resetsAt), current: snapshot(sessionPercent: 85, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        manager.evaluate(previous: snapshot(sessionPercent: 85, resetsAt: resetsAt), current: snapshot(sessionPercent: 60, resetsAt: resetsAt))
        #expect(recorder.events.count == 1, "Dropping below a threshold should not itself notify")
    }

    @Test func refiresAfterDroppingAndCrossingAgain() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.dropandcross")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: resetsAt), current: snapshot(sessionPercent: 85, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        manager.evaluate(previous: snapshot(sessionPercent: 85, resetsAt: resetsAt), current: snapshot(sessionPercent: 60, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        manager.evaluate(previous: snapshot(sessionPercent: 60, resetsAt: resetsAt), current: snapshot(sessionPercent: 82, resetsAt: resetsAt))
        #expect(recorder.events.count == 2, "Crossing 80 again after dropping below it should notify again")
    }

    @Test func rolloverResetsStateSoFreshHighValueNotifiesAgain() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.rollover")
        let firstWindowResetsAt = Date().addingTimeInterval(3600)
        let secondWindowResetsAt = firstWindowResetsAt.addingTimeInterval(3600 * 5)

        manager.evaluate(previous: snapshot(sessionPercent: 70, resetsAt: firstWindowResetsAt), current: snapshot(sessionPercent: 90, resetsAt: firstWindowResetsAt))
        #expect(recorder.events.count == 1)

        // Same 90% level, but resetsAt changed => new window (rollover). Should
        // be treated as a fresh crossing and notify again even though the
        // percent itself did not increase past the level already recorded.
        manager.evaluate(previous: snapshot(sessionPercent: 90, resetsAt: firstWindowResetsAt), current: snapshot(sessionPercent: 90, resetsAt: secondWindowResetsAt))
        #expect(recorder.events.count == 2, "Rollover should reset tracked level and allow re-notification")
    }

    @Test func rolloverDetectedFromPersistedStateWhenPreviousSnapshotIsNil() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.rollover.persisted")
        let firstWindowResetsAt = Date().addingTimeInterval(3600)
        let secondWindowResetsAt = firstWindowResetsAt.addingTimeInterval(3600 * 5)

        // First run (e.g. app cold start) with no previous snapshot in memory.
        manager.evaluate(previous: nil, current: snapshot(sessionPercent: 90, resetsAt: firstWindowResetsAt))
        #expect(recorder.events.count == 1)

        // App restarted again; still no in-memory previous snapshot, but the
        // resetsAt changed since the persisted state -> should be a rollover.
        manager.evaluate(previous: nil, current: snapshot(sessionPercent: 90, resetsAt: secondWindowResetsAt))
        #expect(recorder.events.count == 2)
    }

    @Test func noPreviousAndNoPersistedStateDoesNotDoubleFireOnSameLevel() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.coldstart")
        let resetsAt = Date().addingTimeInterval(3600)

        manager.evaluate(previous: nil, current: snapshot(sessionPercent: 90, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)

        // Cold start again with the exact same window (same resetsAt) -> not a
        // rollover, and persisted level already recorded 90's level, so no refire.
        manager.evaluate(previous: nil, current: snapshot(sessionPercent: 92, resetsAt: resetsAt))
        #expect(recorder.events.count == 1)
    }

    @Test func nilLimitIsIgnoredWithoutCrashing() {
        let (manager, recorder) = makeManager(suiteName: "test.notif.nil")
        let snapshotNoSession = UsageSnapshot(session: nil, weekly: nil, fetchedAt: Date(), isStale: false, needsLogin: false)

        manager.evaluate(previous: nil, current: snapshotNoSession)
        #expect(recorder.events.count == 0)
    }
}
