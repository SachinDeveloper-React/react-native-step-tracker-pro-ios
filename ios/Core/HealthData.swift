import Foundation

/// One Apple Health sample as plain values, so everything built from
/// samples - sources, records, the fallback minutes - is pure and tested
/// without HealthKit.
struct HealthSample: Equatable {
    enum Kind: String { case steps, distance }

    var uuid: String
    var kind: Kind
    var startMs: Int64
    var endMs: Int64
    /// Steps, or metres.
    var value: Double
    var bundleId: String
    var sourceName: String
    /// `HKSourceRevision.productType`, e.g. `iPhone15,2` or `Watch6,1`.
    var productType: String?
    var hasDevice: Bool = false
    var deviceName: String?
    var deviceManufacturer: String?
    var deviceModel: String?
    /// `HKMetadataKeyWasUserEntered`.
    var userEntered: Bool = false
    var syncIdentifier: String?
    var syncVersion: Int?
    /// `HKMetadataKeyTimeZone`.
    var timeZoneName: String?
}

/// Who wrote a sample, as this package classifies it.
enum HealthOrigin {
    static let applePrefix = "com.apple.health."
    static let iPhoneName = "This iPhone"
    static let watchName = "Apple Watch"

    /// Apple's own built-in sources - this iPhone, an Apple Watch - share the
    /// `com.apple.health.<device UUID>` bundle id and differ in product type.
    static func isApple(_ s: HealthSample) -> Bool { s.bundleId.hasPrefix(applePrefix) }

    static func appleKind(_ s: HealthSample) -> StepSourceKind? {
        guard isApple(s) else { return nil }
        let product = (s.productType ?? "").lowercased()
        let model = (s.deviceModel ?? "").lowercased()
        if product.hasPrefix("watch") || model == "watch" { return .watch }
        if product.hasPrefix("iphone") || model == "iphone" { return .phone }
        return nil
    }

    /// This iPhone's own pedometer count: Apple's source on an iPhone, not typed in.
    static func isThisIPhone(_ s: HealthSample) -> Bool { appleKind(s) == .phone && !s.userEntered }

    /// A sample's `HKDevice`, as a kind: from its model and name.
    static func deviceKind(_ s: HealthSample) -> StepSourceKind? {
        guard s.hasDevice else { return nil }
        let text = "\(s.deviceModel ?? "") \(s.deviceName ?? "")".lowercased()
        if text.contains("watch") { return .watch }
        if text.contains("ring") { return .ring }
        if text.contains("band") || text.contains("tracker") { return .fitnessBand }
        if text.contains("strap") || text.contains("chest") { return .chestStrap }
        if text.contains("iphone") || text.contains("phone") { return .phone }
        return nil
    }

    /// The `HealthConnectRecord.device.type` of a sample.
    static func recordDeviceType(_ s: HealthSample) -> String {
        if let apple = appleKind(s) { return apple == .watch ? "watch" : "phone" }
        let model = "\(s.deviceModel ?? "") \(s.deviceName ?? "")".lowercased()
        if model.contains("watch") { return "watch" }
        if model.contains("iphone") || model.contains("phone") { return "phone" }
        return "unknown"
    }

    /// `manual` when typed in, `automatic` from Apple's own sources or a
    /// sample that names its device, else `unknown`.
    static func recordingMethod(_ s: HealthSample) -> String {
        if s.userEntered { return "manual" }
        if isApple(s) || s.hasDevice { return "automatic" }
        return "unknown"
    }
}

/// The iOS catalog for `wearableTrust: 'catalog'`: bundle ids of wearables'
/// companion apps that write steps to Apple Health. Only ids verified in
/// the vendor's documentation or seen as a HealthKit source on a device are
/// listed; candidates still to verify are in docs/IOS_DIFFERENCES.md.
/// Apple Watch is trusted on its own evidence (Apple's source, Watch product
/// type), not by bundle id - every Apple device shares one prefix.
enum IOSCatalog {
    static let wearableBundleIds: [String: (String, StepSourceKind)] = [:]

    static let catalog = SourceCatalog { source in
        (source.isPlatform && source.kind == .watch) || wearableBundleIds[source.packageName] != nil
    }
}

/// Builds one day's sources from its samples - the iOS half of Android's
/// `readSourcesByDay`.
enum HealthSources {
    struct Options {
        var dayStartMs: Int64
        var dayEndMs: Int64
        /// Today's coverage start when it is past midnight; 0 otherwise.
        var coverageStartMs: Int64 = 0
        var countFromMs: Int64 = 0
        var distanceRead: Bool = true
    }

    private struct Acc {
        var bundleId: String
        var name: String
        var kind: StepSourceKind
        var isPlatform: Bool
        var steps = 0.0
        var before = 0.0
        var manual = 0.0
        var manualBefore = 0.0
        var automatic = 0.0
        var unknown = 0.0
        var distance = 0.0
        var distanceSeen = false
        var last: Int64 = 0
        var hourly = [Int](repeating: 0, count: 24)
    }

    /// Of a sample, the part inside [from, to), by time.
    static func clipped(_ s: HealthSample, from: Int64, to: Int64) -> (Int64, Int64, Double)? {
        let start = max(s.startMs, from)
        let end = min(s.endMs, to)
        if s.endMs <= s.startMs {
            return s.startMs >= from && s.startMs < to ? (s.startMs, s.startMs, s.value) : nil
        }
        guard end > start else { return nil }
        let fraction = Double(end - start) / Double(s.endMs - s.startMs)
        return (start, end, s.value * fraction)
    }

    static func appName(_ s: HealthSample) -> String {
        switch HealthOrigin.appleKind(s) {
        case .watch?: return HealthOrigin.watchName
        case .phone?: return HealthOrigin.iPhoneName
        default:
            if let known = IOSCatalog.wearableBundleIds[s.bundleId] { return known.0 }
            return s.sourceName.isEmpty ? s.bundleId : s.sourceName
        }
    }

    static func kind(_ s: HealthSample) -> StepSourceKind {
        if let apple = HealthOrigin.appleKind(s) { return apple }
        if let device = HealthOrigin.deviceKind(s) { return device }
        if let known = IOSCatalog.wearableBundleIds[s.bundleId] { return known.1 }
        return .app
    }

    static func build(_ samples: [HealthSample], _ o: Options, clock: DayClock) -> [StepSource] {
        var accs: [String: Acc] = [:]
        let floor = max(o.dayStartMs, o.countFromMs)
        for s in samples where s.kind == .steps {
            guard let (start, end, value) = clipped(s, from: floor, to: o.dayEndMs), value > 0 else { continue }
            var acc = accs[s.bundleId] ?? Acc(bundleId: s.bundleId, name: appName(s), kind: kind(s),
                                               isPlatform: HealthOrigin.appleKind(s) != nil)
            // A source's kind is its most telling sample's: a wearable stamp wins.
            let k = kind(s)
            if k.isWearable && !acc.kind.isWearable { acc.kind = k }
            acc.steps += value
            if o.coverageStartMs > floor {
                let before = clippedValue(value, start, end, until: o.coverageStartMs)
                acc.before += before
                if s.userEntered { acc.manualBefore += before }
            }
            switch HealthOrigin.recordingMethod(s) {
            case "manual": acc.manual += value
            case "automatic": acc.automatic += value
            default: acc.unknown += value
            }
            acc.last = max(acc.last, s.endMs)
            HourlySteps.add(into: &acc.hourly, startMs: start, endMs: end, count: Int(value.rounded()), clock: clock)
            accs[s.bundleId] = acc
        }
        if o.distanceRead {
            for s in samples where s.kind == .distance {
                guard var acc = accs[s.bundleId],
                      let (_, _, value) = clipped(s, from: floor, to: o.dayEndMs) else { continue }
                acc.distance += value
                acc.distanceSeen = true
                accs[s.bundleId] = acc
            }
        }
        return accs.values.map { a -> StepSource in
            let steps = a.hourly.reduce(0, +)
            var methods = RecordingMethods(active: 0, automatic: Int(a.automatic.rounded()),
                                           manual: Int(a.manual.rounded()), unknown: Int(a.unknown.rounded()))
            // The buckets sum to steps exactly; rounding drift goes to the largest.
            let drift = steps - (methods.automatic + methods.manual + methods.unknown)
            if drift != 0 {
                if methods.automatic >= methods.manual && methods.automatic >= methods.unknown {
                    methods.automatic += drift
                } else if methods.manual >= methods.unknown {
                    methods.manual += drift
                } else {
                    methods.unknown += drift
                }
            }
            return StepSource(
                packageName: a.bundleId, appName: a.name, kind: a.kind, steps: steps,
                distance: a.distanceSeen ? a.distance : 0, calories: 0, lastRecordAt: a.last, isSelf: false,
                stepsBeforeCoverage: o.coverageStartMs > floor ? Int(a.before.rounded()) : -1,
                manualSteps: methods.manual, unknownMethodSteps: methods.unknown, recordingMethods: methods,
                manualStepsBeforeCoverage: o.coverageStartMs > floor ? Int(a.manualBefore.rounded()) : -1,
                lateWrittenSteps: -1, hourlySteps: a.hourly, activeCalories: 0,
                distanceSource: !o.distanceRead ? DistanceSource.notRead
                    : (a.distanceSeen ? DistanceSource.healthKit : DistanceSource.none),
                isPlatform: a.isPlatform)
        }
        .filter { $0.steps > 0 }
        .sorted { $0.steps != $1.steps ? $0.steps > $1.steps : $0.packageName < $1.packageName }
    }

    private static func clippedValue(_ value: Double, _ start: Int64, _ end: Int64, until: Int64) -> Double {
        if start >= until { return 0 }
        if end <= until || end <= start { return value }
        return value * Double(until - start) / Double(end - start)
    }

    /// The fallback minutes: this iPhone's own samples, spread over the
    /// minutes they cover, within the counting windows.
    static func iPhoneMinutes(_ samples: [HealthSample], windows: [(Int64, Int64)]) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for s in samples where s.kind == .steps && HealthOrigin.isThisIPhone(s) {
            for w in windows {
                guard let (start, end, value) = clipped(s, from: w.0, to: w.1) else { continue }
                let steps = Int(value.rounded())
                for (minute, share) in MinuteAttribution.spread(start, max(end, start + 1), steps) {
                    out[minute, default: 0] += share
                }
            }
        }
        return out
    }

    // ---- records ----------------------------------------------------------------

    /// A `HealthConnectRecord` / `HealthConnectDistanceRecord`.
    static func record(_ s: HealthSample) -> JSON {
        var pairs: [(String, JSON)] = [
            ("recordType", .string(s.kind.rawValue)),
            ("id", .string(s.uuid)),
            ("clientRecordId", .optional(s.syncIdentifier)),
            ("clientRecordVersion", .int(s.syncVersion ?? 0)),
            ("packageName", .string(s.bundleId)),
            ("recordingMethod", .string(HealthOrigin.recordingMethod(s))),
            ("device", s.hasDevice || HealthOrigin.isApple(s)
                ? .object([("type", .string(HealthOrigin.recordDeviceType(s))),
                           ("manufacturer", .optional(s.deviceManufacturer)),
                           ("model", .optional(s.deviceModel))])
                : .null),
            ("startTime", .int(s.startMs)),
            ("endTime", .int(s.endMs)),
            ("startZoneOffsetSeconds", zoneOffset(s, at: s.startMs)),
            ("endZoneOffsetSeconds", zoneOffset(s, at: s.endMs)),
            ("lastModifiedTime", .int(0)),
        ]
        switch s.kind {
        case .steps: pairs.append(("count", .int(Int64(s.value.rounded()))))
        case .distance: pairs.append(("distanceMeters", .double(s.value)))
        }
        return .object(pairs)
    }

    private static func zoneOffset(_ s: HealthSample, at ms: Int64) -> JSON {
        guard let name = s.timeZoneName, let zone = TimeZone(identifier: name) else { return .null }
        return .int(zone.secondsFromGMT(for: DayClock.date(ms)))
    }

    /// At most this many records of one type per read, as on Android.
    static let maxRecordsPerType = 10_000

    /// Oldest first, whichever type; `truncated` when a type had more.
    static func recordList(_ samples: [HealthSample], types: [HealthSample.Kind]) -> (JSON, Bool) {
        var out: [HealthSample] = []
        var truncated = false
        for type in types {
            let ofType = samples.filter { $0.kind == type }.sorted { $0.startMs < $1.startMs }
            if ofType.count > maxRecordsPerType { truncated = true }
            out += ofType.prefix(maxRecordsPerType)
        }
        out.sort { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.uuid < $1.uuid }
        return (.array(out.map(record)), truncated)
    }
}
