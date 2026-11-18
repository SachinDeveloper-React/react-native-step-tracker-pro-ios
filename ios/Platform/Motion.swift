import CoreMotion
import Foundation

/// CMPedometer and CMMotionActivityManager, asked synchronously from the
/// engine's queue: each callback only stores its answer and signals, so the
/// queue never waits on itself.
final class MotionSource {
    private let pedometer = CMPedometer()
    private let activity = CMMotionActivityManager()
    private let callbackQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "StepTrackerPro.motion"
        q.maxConcurrentOperationCount = 4
        return q
    }()

    static let timeout: TimeInterval = 8

    var pedometerAvailable: Bool { CMPedometer.isStepCountingAvailable() }
    var activityAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    /// Motion & Fitness, which covers both.
    var authorization: CMAuthorizationStatus { CMPedometer.authorizationStatus() }
    var authorized: Bool { authorization == .authorized }

    /// Steps between two instants; nil when the pedometer did not answer.
    func steps(from: Int64, to: Int64) -> Int? {
        guard to > from else { return 0 }
        let sem = DispatchSemaphore(value: 0)
        var result: Int?
        pedometer.queryPedometerData(from: DayClock.date(from), to: DayClock.date(to)) { data, error in
            if error == nil { result = data?.numberOfSteps.intValue ?? 0 }
            sem.signal()
        }
        return sem.wait(timeout: .now() + MotionSource.timeout) == .success ? result : nil
    }

    /// Many intervals at once; nil for any that did not answer.
    func steps(_ intervals: [(Int64, Int64)]) -> [Int?] {
        guard !intervals.isEmpty else { return [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var results = [Int?](repeating: nil, count: intervals.count)
        for (i, interval) in intervals.enumerated() {
            if interval.1 <= interval.0 {
                results[i] = 0
                continue
            }
            group.enter()
            pedometer.queryPedometerData(from: DayClock.date(interval.0), to: DayClock.date(interval.1)) { data, error in
                lock.lock()
                if error == nil { results[i] = data?.numberOfSteps.intValue ?? 0 }
                lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + MotionSource.timeout * 2)
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    /// Steps and metres over the last week, for the Health grant inference.
    func recentTotals(days: Int = 7) -> (steps: Int, distance: Double)? {
        let now = Date()
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Double)?
        pedometer.queryPedometerData(from: now.addingTimeInterval(-Double(days) * 86_400 + 60), to: now) { data, error in
            if error == nil, let data { result = (data.numberOfSteps.intValue, data.distance?.doubleValue ?? 0) }
            sem.signal()
        }
        return sem.wait(timeout: .now() + MotionSource.timeout) == .success ? result : nil
    }

    /// A tiny query: CoreMotion has no request call, and this raises the
    /// Motion & Fitness prompt when it has not been answered.
    func requestAuthorization(done: @escaping () -> Void) {
        let now = Date()
        pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in done() }
    }

    func activities(from: Int64, to: Int64) -> [ActivitySample]? {
        guard activityAvailable, authorized, to > from else { return [] }
        let sem = DispatchSemaphore(value: 0)
        var result: [ActivitySample]?
        activity.queryActivityStarting(from: DayClock.date(from), to: DayClock.date(to), to: callbackQueue) { list, error in
            if error == nil {
                result = (list ?? []).map { a in
                    ActivitySample(startMs: DayClock.ms(a.startDate), stationary: a.stationary, walking: a.walking,
                                   running: a.running, automotive: a.automotive, cycling: a.cycling, unknown: a.unknown,
                                   confidence: a.confidence.rawValue)
                }
            }
            sem.signal()
        }
        return sem.wait(timeout: .now() + MotionSource.timeout) == .success ? result : nil
    }

    // ---- live --------------------------------------------------------------------------

    private(set) var liveFrom: Int64 = 0

    /// Cumulative steps since [from], on every change, while the app is in
    /// the foreground. The coprocessor counts regardless; this is only
    /// what makes the number move on screen.
    func startLive(from: Int64, onUpdate: @escaping (Int, Int64) -> Void, onError: @escaping (Error) -> Void) {
        stopLive()
        liveFrom = from
        pedometer.startUpdates(from: DayClock.date(from)) { data, error in
            if let error { return onError(error) }
            guard let data else { return }
            onUpdate(data.numberOfSteps.intValue, DayClock.ms(data.endDate))
        }
    }

    func stopLive() {
        if liveFrom != 0 { pedometer.stopUpdates() }
        liveFrom = 0
    }
}
