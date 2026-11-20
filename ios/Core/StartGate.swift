import Foundation

/// Runs a piece of work exactly once, from whichever thread calls first.
final class Once {
    private var work: (() -> Void)?
    private let lock = NSLock()

    init(_ work: @escaping () -> Void) { self.work = work }

    func run() {
        lock.lock()
        let w = work
        work = nil
        lock.unlock()
        w?()
    }
}

/// Work that needs the engine started, held while it cannot start and run
/// once it has, in the order it was asked for.
///
/// Before the first unlock after a reboot the engine's files cannot be
/// read, and an engine started on a blank state would save it over
/// everything kept as soon as the phone unlocked. So it waits for the
/// unlock, and so does everything that needs it. Used on one serial queue.
final class StartGate {
    private let queue: DispatchQueue
    private let start: () -> Bool
    private let whenReady: (@escaping () -> Void) -> Void
    private(set) var started = false
    private var waiting = false
    private var held: [() -> Void] = []

    /// [start] starts the engine, or returns false, with nothing done, when
    /// it cannot yet; [whenReady] calls back, from any thread, when it may.
    init(queue: DispatchQueue, start: @escaping () -> Bool, whenReady: @escaping (@escaping () -> Void) -> Void) {
        self.queue = queue
        self.start = start
        self.whenReady = whenReady
    }

    /// Starts the engine unless it has started or is waiting. True once started.
    @discardableResult
    func startIfNeeded() -> Bool {
        if started { return true }
        if waiting { return false }
        guard start() else {
            waiting = true
            let retry = Once {
                self.queue.async {
                    self.waiting = false
                    self.startIfNeeded()
                }
            }
            whenReady { retry.run() }
            return false
        }
        started = true
        let work = held
        held = []
        work.forEach { $0() }
        return true
    }

    /// [work] now, on a started engine - starting it first if it can - or
    /// once it has started, after everything asked before it.
    func afterStart(_ work: @escaping () -> Void) {
        if startIfNeeded() {
            work()
        } else {
            held.append(work)
        }
    }
}
