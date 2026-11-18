import Foundation
import HealthKit

/// Apple Health, read only: `stepCount` and `distanceWalkingRunning`, never
/// energy, never written. Queried synchronously from the engine's queue.
final class HealthSource {
    enum ReadError: Error {
        case timedOut
        /// The phone is locked and the store protected, or HealthKit refused.
        case failed(Error?)
    }

    let store = HKHealthStore()
    static let timeout: TimeInterval = 15

    static let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    static let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!

    static func type(_ kind: HealthSample.Kind) -> HKQuantityType { kind == .steps ? stepType : distanceType }

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The usage string HealthKit terminates the app without, and the entitlement.
    static var missingDeclaration: String? {
        if !DeviceInfo.hasInfoKey("NSHealthShareUsageDescription") {
            return "NSHealthShareUsageDescription is missing from the app's Info.plist; Apple Health cannot be read without it."
        }
        if DeviceInfo.hasEntitlement("com.apple.developer.healthkit") == false {
            return "The app is not signed with the com.apple.developer.healthkit entitlement; add the HealthKit capability in Xcode."
        }
        return nil
    }

    // ---- authorization ------------------------------------------------------------------

    func requestStatus(_ kinds: [HealthSample.Kind]) -> HKAuthorizationRequestStatus {
        guard available, HealthSource.missingDeclaration == nil else { return .unknown }
        let sem = DispatchSemaphore(value: 0)
        var status = HKAuthorizationRequestStatus.unknown
        store.getRequestStatusForAuthorization(toShare: [], read: Set(kinds.map(HealthSource.type))) { s, _ in
            status = s
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return status
    }

    func requestAuthorization(_ kinds: [HealthSample.Kind], done: @escaping (Error?) -> Void) {
        // toShare is empty: this package never writes to Apple Health.
        store.requestAuthorization(toShare: [], read: Set(kinds.map(HealthSource.type))) { _, error in done(error) }
    }

    // ---- samples ----------------------------------------------------------------------------

    /// Every sample of [kind] overlapping [from, to), oldest first.
    func samples(_ kind: HealthSample.Kind, from: Int64, to: Int64, limit: Int = HKObjectQueryNoLimit,
                 predicate extra: NSPredicate? = nil) -> Result<[HealthSample], ReadError> {
        var predicate: NSPredicate = HKQuery.predicateForSamples(withStart: DayClock.date(from), end: DayClock.date(to), options: [])
        if let extra { predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, extra]) }
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[HealthSample], ReadError> = .failure(.timedOut)
        let query = HKSampleQuery(sampleType: HealthSource.type(kind), predicate: predicate, limit: limit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, results, error in
            if let error {
                outcome = .failure(.failed(error))
            } else {
                outcome = .success((results ?? []).compactMap { $0 as? HKQuantitySample }.map { HealthSource.plain($0, kind) })
            }
            sem.signal()
        }
        store.execute(query)
        if sem.wait(timeout: .now() + HealthSource.timeout) == .timedOut {
            store.stop(query)
            return .failure(.timedOut)
        }
        return outcome
    }

    static func plain(_ s: HKQuantitySample, _ kind: HealthSample.Kind) -> HealthSample {
        let revision = s.sourceRevision
        let meta = s.metadata ?? [:]
        let syncVersion = (meta[HKMetadataKeySyncVersion] as? NSNumber)?.intValue
        return HealthSample(
            uuid: s.uuid.uuidString, kind: kind, startMs: DayClock.ms(s.startDate), endMs: DayClock.ms(s.endDate),
            value: s.quantity.doubleValue(for: kind == .steps ? .count() : .meter()),
            bundleId: revision.source.bundleIdentifier, sourceName: revision.source.name,
            productType: revision.productType, hasDevice: s.device != nil, deviceName: s.device?.name,
            deviceManufacturer: s.device?.manufacturer, deviceModel: s.device?.model,
            userEntered: (meta[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue ?? false,
            syncIdentifier: meta[HKMetadataKeySyncIdentifier] as? String, syncVersion: syncVersion,
            timeZoneName: meta[HKMetadataKeyTimeZone] as? String)
    }

    /// Whether any source has a sample of [kind] in the last week - the
    /// only way to tell a granted read from a refused one, which HealthKit
    /// hides.
    func hasRecentSample(_ kind: HealthSample.Kind, days: Int = 7) -> Bool? {
        let now = DeviceInfo.nowMs()
        switch samples(kind, from: now - Int64(days) * 86_400_000, to: now, limit: 1) {
        case let .success(list): return !list.isEmpty
        case .failure: return nil
        }
    }

    /// Per-day totals across every source, de-duplicated by Apple Health.
    func dailyTotals(_ kind: HealthSample.Kind, from: Int64, to: Int64, clock: DayClock) -> Result<[String: Double], ReadError> {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[String: Double], ReadError> = .failure(.timedOut)
        let anchor = clock.calendar.startOfDay(for: DayClock.date(from))
        let query = HKStatisticsCollectionQuery(
            quantityType: HealthSource.type(kind),
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: DayClock.date(from), end: DayClock.date(to), options: []),
            options: .cumulativeSum, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
        query.initialResultsHandler = { _, collection, error in
            if let error {
                outcome = .failure(.failed(error))
            } else {
                var out: [String: Double] = [:]
                collection?.enumerateStatistics(from: DayClock.date(from), to: DayClock.date(to)) { stats, _ in
                    let value = stats.sumQuantity()?.doubleValue(for: kind == .steps ? .count() : .meter()) ?? 0
                    out[clock.key(stats.startDate), default: 0] += value
                }
                outcome = .success(out)
            }
            sem.signal()
        }
        store.execute(query)
        if sem.wait(timeout: .now() + HealthSource.timeout) == .timedOut {
            store.stop(query)
            return .failure(.timedOut)
        }
        return outcome
    }

    /// Per-source totals over a long range - Android's aggregate path - by bundle id.
    func sourceTotals(_ kind: HealthSample.Kind, from: Int64, to: Int64) -> Result<[(String, String, Double)], ReadError> {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[(String, String, Double)], ReadError> = .failure(.timedOut)
        let query = HKStatisticsQuery(
            quantityType: HealthSource.type(kind),
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: DayClock.date(from), end: DayClock.date(to), options: []),
            options: [.cumulativeSum, .separateBySource]) { _, stats, error in
            if let error {
                outcome = .failure(.failed(error))
            } else {
                let unit: HKUnit = kind == .steps ? .count() : .meter()
                outcome = .success((stats?.sources ?? []).map { source in
                    (source.bundleIdentifier, source.name, stats?.sumQuantity(for: source)?.doubleValue(for: unit) ?? 0)
                })
            }
            sem.signal()
        }
        store.execute(query)
        if sem.wait(timeout: .now() + HealthSource.timeout) == .timedOut {
            store.stop(query)
            return .failure(.timedOut)
        }
        return outcome
    }

    /// Per-day totals by source, for long ranges.
    func dailySourceTotals(_ kind: HealthSample.Kind, from: Int64, to: Int64, clock: DayClock) -> Result<[String: [(String, String, Double)]], ReadError> {
        guard to > from else { return .success([:]) }
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[String: [(String, String, Double)]], ReadError> = .failure(.timedOut)
        let query = HKStatisticsCollectionQuery(
            quantityType: HealthSource.type(kind),
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: DayClock.date(from), end: DayClock.date(to), options: []),
            options: [.cumulativeSum, .separateBySource], anchorDate: clock.calendar.startOfDay(for: DayClock.date(from)),
            intervalComponents: DateComponents(day: 1))
        query.initialResultsHandler = { _, collection, error in
            if let error {
                outcome = .failure(.failed(error))
            } else {
                let unit: HKUnit = kind == .steps ? .count() : .meter()
                var out: [String: [(String, String, Double)]] = [:]
                collection?.enumerateStatistics(from: DayClock.date(from), to: DayClock.date(to)) { stats, _ in
                    let rows = (stats.sources ?? []).map { ($0.bundleIdentifier, $0.name, stats.sumQuantity(for: $0)?.doubleValue(for: unit) ?? 0) }
                    out[clock.key(stats.startDate), default: []] += rows
                }
                outcome = .success(out)
            }
            sem.signal()
        }
        store.execute(query)
        if sem.wait(timeout: .now() + HealthSource.timeout * 2) == .timedOut {
            store.stop(query)
            return .failure(.timedOut)
        }
        return outcome
    }

    // ---- change tracking -------------------------------------------------------------------

    func anchored(_ kind: HealthSample.Kind, anchor: HKQueryAnchor?, predicate: NSPredicate?, limit: Int)
        -> Result<(samples: [HealthSample], deleted: [String], anchor: HKQueryAnchor?), ReadError> {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<(samples: [HealthSample], deleted: [String], anchor: HKQueryAnchor?), ReadError> = .failure(.timedOut)
        let query = HKAnchoredObjectQuery(type: HealthSource.type(kind), predicate: predicate, anchor: anchor, limit: limit) { _, added, deleted, next, error in
            if let error {
                outcome = .failure(.failed(error))
            } else {
                let plain = (added ?? []).compactMap { $0 as? HKQuantitySample }.map { HealthSource.plain($0, kind) }
                outcome = .success((plain, (deleted ?? []).map { $0.uuid.uuidString }, next))
            }
            sem.signal()
        }
        store.execute(query)
        if sem.wait(timeout: .now() + HealthSource.timeout) == .timedOut {
            store.stop(query)
            return .failure(.timedOut)
        }
        return outcome
    }

    static func archive(_ anchor: HKQueryAnchor?) -> String? {
        guard let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return nil }
        return data.base64EncodedString()
    }

    static func unarchive(_ text: String) -> HKQueryAnchor? {
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    // ---- background -------------------------------------------------------------------------

    private var observers: [HKObserverQuery] = []

    /// Observer queries for the granted types, and hourly background
    /// delivery - the most often iOS allows for steps.
    func observe(_ kinds: [HealthSample.Kind], onChange: @escaping (_ done: @escaping () -> Void) -> Void,
                 onError: @escaping (String) -> Void) {
        guard observers.isEmpty else { return }
        for kind in kinds {
            let type = HealthSource.type(kind)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if error != nil { return completion() }
                onChange(completion)
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { ok, error in
                if !ok { onError(error?.localizedDescription ?? "Apple Health background delivery was not enabled") }
            }
        }
    }

    var observing: Bool { !observers.isEmpty }

    static func isLockedError(_ error: Error?) -> Bool {
        guard let error = error as? HKError else { return false }
        return error.code == .errorDatabaseInaccessible
    }
}
