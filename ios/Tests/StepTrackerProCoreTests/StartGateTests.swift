import XCTest
@testable import StepTrackerProCore

/// A launch before the first unlock after a reboot: the engine cannot read
/// its files, so it starts at the unlock, and what was asked meanwhile runs
/// then, in the order asked, on what was kept.
final class StartGateTests: XCTestCase {
    /// What ran, in order, from whichever thread.
    final class Log {
        private let lock = NSLock()
        private var items: [String] = []

        func add(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// The phone: whether the engine's files can be read, and the unlock
    /// notification, called on whatever waits for it.
    final class Phone {
        private let lock = NSLock()
        private var waiting: [() -> Void] = []
        private var unlocked = false

        var readable: Bool {
            lock.lock()
            defer { lock.unlock() }
            return unlocked
        }

        var waiters: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiting.count
        }

        func whenUnlocked(_ ready: @escaping () -> Void) {
            lock.lock()
            waiting.append(ready)
            lock.unlock()
        }

        /// The notification; [readable] is whether the files can be read after it.
        func notify(readable: Bool) {
            lock.lock()
            unlocked = readable
            let ready = waiting
            waiting = []
            lock.unlock()
            ready.forEach { $0() }
        }
    }

    /// Waits until [condition] holds, for up to two seconds.
    func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// An engine whose start reads its files, counting the attempts.
    func gate(_ queue: DispatchQueue, _ phone: Phone, _ log: Log) -> (StartGate, () -> Int) {
        var attempts = 0
        let gate = StartGate(queue: queue, start: {
            attempts += 1
            guard phone.readable else { return false }
            log.add("started after \(attempts)")
            return true
        }, whenReady: phone.whenUnlocked)
        return (gate, { queue.sync { attempts } })
    }

    func testWhatWasAskedRunsInOrderOnceTheEngineStartsHoweverManyUnlocksItTakes() {
        let queue = DispatchQueue(label: "gate.order")
        let phone = Phone()
        let log = Log()
        let (gate, attempts) = self.gate(queue, phone, log)
        let done = expectation(description: "calls answered")
        done.expectedFulfillmentCount = 3
        queue.async { gate.afterStart { log.add("call 1"); done.fulfill() } }
        queue.async { gate.afterStart { log.add("call 2"); done.fulfill() } }
        XCTAssertTrue(eventually { phone.waiters == 1 })
        queue.async { gate.afterStart { log.add("call 3"); done.fulfill() } }
        // An unlock report while the files still cannot be read: it waits again.
        phone.notify(readable: false)
        XCTAssertTrue(eventually { phone.waiters == 1 })
        XCTAssertEqual(log.all, [], "nothing runs on an engine that has not started")
        phone.notify(readable: true)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.all, ["started after 3", "call 1", "call 2", "call 3"])
        XCTAssertEqual(attempts(), 3)
    }

    func testAnUnlockReportedTwiceStartsOnce() {
        let queue = DispatchQueue(label: "gate.twice")
        let log = Log()
        var attempts = 0
        let reported = expectation(description: "reported twice")
        let gate = StartGate(queue: queue, start: {
            attempts += 1
            return attempts > 1
        }, whenReady: { ready in
            ready()
            DispatchQueue.global().async {
                ready()
                reported.fulfill()
            }
        })
        queue.async { gate.afterStart { log.add("call") } }
        wait(for: [reported], timeout: 5)
        queue.sync {}
        queue.sync {}
        XCTAssertEqual(log.all, ["call"])
        XCTAssertEqual(queue.sync { attempts }, 2)
    }

    func testOnceStartedWorkRunsAtOnce() {
        let queue = DispatchQueue(label: "gate.started")
        let phone = Phone()
        phone.notify(readable: true)
        let log = Log()
        let (gate, attempts) = self.gate(queue, phone, log)
        queue.sync { gate.afterStart { log.add("a") } }
        queue.sync { gate.afterStart { log.add("b") } }
        XCTAssertEqual(log.all, ["started after 1", "a", "b"])
        XCTAssertEqual(attempts(), 1)
        XCTAssertEqual(phone.waiters, 0)
    }
}
