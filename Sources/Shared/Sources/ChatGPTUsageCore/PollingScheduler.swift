import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Generic periodic-refresh scheduler. It knows nothing about networking or
/// WebViews — callers hand it a `task` closure to invoke on a timer, on
/// demand (`refreshNow`), and immediately after the Mac wakes from sleep
/// (since a 5-minute timer can otherwise be delayed for a long time across a
/// sleep/wake cycle).
public final class PollingScheduler {
    private let interval: TimeInterval
    private var timer: Timer?
    private var task: (() async -> Void)?
    private var wakeObserver: NSObjectProtocol?

    public init(interval: TimeInterval = 300) {
        self.interval = interval
    }

    public func start(task: @escaping () async -> Void) {
        self.task = task

        invalidateTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        removeWakeObserver()
        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fire()
        }
        #endif
    }

    public func stop() {
        invalidateTimer()
        removeWakeObserver()
        task = nil
    }

    /// Runs `task` immediately, outside of the regular interval.
    public func refreshNow() {
        fire()
    }

    private func fire() {
        guard let task else { return }
        Task {
            await task()
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func removeWakeObserver() {
        #if canImport(AppKit)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        #endif
        wakeObserver = nil
    }

    deinit {
        stop()
    }
}
