import Foundation

/// The Apple Health types with an observer query, and the one lock both
/// registrations go through.
///
/// Two places register them. The launch, on the main thread, with the types
/// the last run kept: HealthKit hands a background launch's delivery to the
/// observers that exist as launch finishes, before the engine has started.
/// And the engine, on its queue, with the types its config and the grant
/// call for. Each one decides and acts under the lock, so neither acts on
/// what the other has half done - no "is anything observed?" read on one
/// thread and a registration on another in between - and once the engine
/// has set the types, the launch's list, which can be older, is not
/// applied over them.
final class ObservedTypes<Query> {
    private var queries: [HealthSample.Kind: Query] = [:]
    private var setByEngine = false
    private let lock = NSLock()

    init() {}

    /// The types observed now, steps first.
    var kinds: [HealthSample.Kind] {
        lock.lock()
        defer { lock.unlock() }
        return [HealthSample.Kind.steps, .distance].filter { queries[$0] != nil }
    }

    /// At launch: [start] for each of [kinds] without an observer, unless
    /// the engine has already set the types. Returns the types started.
    @discardableResult
    func launch(_ kinds: [HealthSample.Kind], start: (HealthSample.Kind) -> Query) -> [HealthSample.Kind] {
        lock.lock()
        defer { lock.unlock() }
        guard !setByEngine else { return [] }
        return startMissing(kinds, start)
    }

    /// From the engine: exactly [kinds] - [start] for each without an
    /// observer, [stop] for each observed type no longer wanted. Returns the
    /// types started.
    @discardableResult
    func set(_ kinds: [HealthSample.Kind], start: (HealthSample.Kind) -> Query,
             stop: (HealthSample.Kind, Query) -> Void) -> [HealthSample.Kind] {
        lock.lock()
        defer { lock.unlock() }
        setByEngine = true
        for (kind, query) in queries where !kinds.contains(kind) {
            stop(kind, query)
            queries[kind] = nil
        }
        return startMissing(kinds, start)
    }

    private func startMissing(_ kinds: [HealthSample.Kind], _ start: (HealthSample.Kind) -> Query) -> [HealthSample.Kind] {
        var started: [HealthSample.Kind] = []
        for kind in kinds where queries[kind] == nil {
            queries[kind] = start(kind)
            started.append(kind)
        }
        return started
    }
}
