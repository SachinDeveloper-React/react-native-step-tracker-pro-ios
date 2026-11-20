import XCTest
@testable import StepTrackerProCore

/// Observer queries registered from two threads: the launch's, on the main
/// thread, with the types the last run kept, and the engine's, on its
/// queue, with the types its config and the grant call for.
final class ObservedTypesTests: XCTestCase {
    /// A stand-in for an `HKObserverQuery`.
    final class Query {}

    /// What was started and stopped, from whichever thread.
    final class Log {
        private let lock = NSLock()
        private var startedKinds: [HealthSample.Kind] = []
        private var stoppedKinds: [HealthSample.Kind] = []

        var started: [HealthSample.Kind] { lock.lock(); defer { lock.unlock() }; return startedKinds }
        var stopped: [HealthSample.Kind] { lock.lock(); defer { lock.unlock() }; return stoppedKinds }

        func start(_ kind: HealthSample.Kind) -> Query {
            lock.lock()
            startedKinds.append(kind)
            lock.unlock()
            return Query()
        }

        func stop(_ kind: HealthSample.Kind, _ query: Query) {
            lock.lock()
            stoppedKinds.append(kind)
            lock.unlock()
        }

        /// Observers of [kind] started and not stopped.
        func live(_ kind: HealthSample.Kind) -> Int {
            started.filter { $0 == kind }.count - stopped.filter { $0 == kind }.count
        }
    }

    func testTheLaunchStartsTheTypesTheLastRunKept() {
        let observed = ObservedTypes<Query>()
        let log = Log()
        XCTAssertEqual(observed.launch([.steps, .distance], start: log.start), [.steps, .distance])
        XCTAssertEqual(observed.kinds, [.steps, .distance])
    }

    func testTheEngineAddsATypeTheLastRunDidNotObserve() {
        // distance joined healthConnectReadTypes since the last run.
        let observed = ObservedTypes<Query>()
        let log = Log()
        observed.launch([.steps], start: log.start)
        XCTAssertEqual(observed.set([.steps, .distance], start: log.start, stop: log.stop), [.distance])
        XCTAssertEqual(observed.kinds, [.steps, .distance])
        XCTAssertEqual(log.started, [.steps, .distance], "steps is not started twice")
    }

    func testTheEngineStopsATypeNoLongerRead() {
        let observed = ObservedTypes<Query>()
        let log = Log()
        observed.launch([.steps, .distance], start: log.start)
        XCTAssertEqual(observed.set([.steps], start: log.start, stop: log.stop), [])
        XCTAssertEqual(observed.kinds, [.steps])
        XCTAssertEqual(log.stopped, [.distance])
    }

    func testAppleHealthTurnedOffStopsEveryObserver() {
        let observed = ObservedTypes<Query>()
        let log = Log()
        observed.launch([.steps, .distance], start: log.start)
        observed.set([], start: log.start, stop: log.stop)
        XCTAssertEqual(observed.kinds, [])
        XCTAssertEqual(Set(log.stopped), [.steps, .distance])
    }

    func testOnceTheEngineHasSetTheTypesTheLaunchChangesNothing() {
        // The engine's queue got there first: a module call beat the launch notification.
        let observed = ObservedTypes<Query>()
        let log = Log()
        observed.set([.steps], start: log.start, stop: log.stop)
        XCTAssertEqual(observed.launch([.steps, .distance], start: log.start), [], "the launch's list is older")
        XCTAssertEqual(observed.kinds, [.steps])
        observed.set([], start: log.start, stop: log.stop)
        observed.launch([.steps], start: log.start)
        XCTAssertEqual(observed.kinds, [], "turned off stays off")
    }

    func testAskingAgainStartsNothingTwice() {
        let observed = ObservedTypes<Query>()
        let log = Log()
        observed.launch([.steps], start: log.start)
        observed.launch([.steps], start: log.start)
        observed.set([.steps], start: log.start, stop: log.stop)
        observed.set([.steps, .steps], start: log.start, stop: log.stop)
        XCTAssertEqual(log.started, [.steps])
        XCTAssertEqual(log.stopped, [])
    }

    /// The race: whichever thread gets there first, what is observed is the
    /// engine's types, and no type ever has two observers.
    func testTheLaunchAndTheEngineOnTwoThreadsAlwaysEndWithTheEnginesTypes() {
        // (engine, launch): a type added since the last run, one removed, the
        // same, Apple Health turned off.
        let cases: [([HealthSample.Kind], [HealthSample.Kind])] = [
            ([.steps, .distance], [.steps]), ([.steps], [.steps, .distance]), ([.steps], [.steps]), ([], [.steps, .distance]),
        ]
        for round in 0..<2_000 {
            let observed = ObservedTypes<Query>()
            let log = Log()
            let (engine, launch) = cases[round % cases.count]
            // Each side is started first in half the rounds of every case.
            let launchFirst = (round / cases.count) % 2 == 0
            DispatchQueue.concurrentPerform(iterations: 2) { thread in
                if (thread == 0) == launchFirst {
                    observed.launch(launch, start: log.start)
                } else {
                    observed.set(engine, start: log.start, stop: log.stop)
                }
            }
            XCTAssertEqual(observed.kinds, engine, "round \(round)")
            for kind in [HealthSample.Kind.steps, .distance] {
                XCTAssertEqual(log.live(kind), engine.contains(kind) ? 1 : 0, "round \(round), \(kind)")
            }
        }
    }
}
