import Foundation

enum StepSourcePolicy: String, CaseIterable {
    case device, wearable
    case healthConnect = "health_connect"
    case auto

    static func from(_ value: String?) -> StepSourcePolicy { value.flatMap(StepSourcePolicy.init(rawValue:)) ?? .auto }
}

enum WearableTrust: String {
    case metadata, catalog

    static func from(_ value: String?) -> WearableTrust { value.flatMap(WearableTrust.init(rawValue:)) ?? .metadata }
}

enum StepSourceKind: String {
    case selfSource = "self"
    case watch
    case fitnessBand = "fitness_band"
    case ring
    case chestStrap = "chest_strap"
    case phone, app, unknown

    var isWearable: Bool { self == .watch || self == .fitnessBand || self == .ring || self == .chestStrap }
}

/// How a source's steps were produced. The four buckets sum to its steps.
struct RecordingMethods: Equatable {
    var active = 0
    var automatic = 0
    var manual = 0
    var unknown = 0

    func json() -> JSON {
        .object([("active", .int(active)), ("automatic", .int(automatic)), ("manual", .int(manual)), ("unknown", .int(unknown))])
    }
}

/// Where a distance figure came from.
enum DistanceSource {
    static let healthConnect = "health_connect"
    /// iOS: the source's own `distanceWalkingRunning` samples.
    static let healthKit = "healthkit"
    static let derived = "derived"
    static let none = "none"
    static let notRead = "not_read"
}

/// One app or device contributing steps to the health store over a range -
/// the port of Android's `StepSource`. On iOS `packageName` is the source's
/// bundle id, and `isPlatform` is stored rather than derived from the name:
/// Apple's own sources (this iPhone, an Apple Watch) share one bundle-id
/// prefix and are told apart by product type.
struct StepSource: Equatable {
    var packageName: String
    var appName: String
    var kind: StepSourceKind
    var steps: Int
    var distance: Double
    var calories: Double
    var lastRecordAt: Int64
    var isSelf: Bool
    var stepsBeforeCoverage: Int = -1
    var manualSteps: Int = -1
    var unknownMethodSteps: Int = -1
    var recordingMethods: RecordingMethods? = nil
    var manualStepsBeforeCoverage: Int = -1
    var trustedWearable: Bool
    var lateWrittenSteps: Int = -1
    var hourlySteps: [Int] = HourlySteps.unknown
    var activeCalories: Double = -1
    var distanceSource: String = DistanceSource.none
    var isPlatform: Bool = false

    init(packageName: String, appName: String, kind: StepSourceKind, steps: Int, distance: Double = 0,
         calories: Double = 0, lastRecordAt: Int64 = 0, isSelf: Bool = false, stepsBeforeCoverage: Int = -1,
         manualSteps: Int = -1, unknownMethodSteps: Int = -1, recordingMethods: RecordingMethods? = nil,
         manualStepsBeforeCoverage: Int = -1, trustedWearable: Bool? = nil, lateWrittenSteps: Int = -1,
         hourlySteps: [Int] = HourlySteps.unknown, activeCalories: Double = -1,
         distanceSource: String = DistanceSource.none, isPlatform: Bool = false) {
        self.packageName = packageName
        self.appName = appName
        self.kind = kind
        self.steps = steps
        self.distance = distance
        self.calories = calories
        self.lastRecordAt = lastRecordAt
        self.isSelf = isSelf
        self.stepsBeforeCoverage = stepsBeforeCoverage
        self.manualSteps = manualSteps
        self.unknownMethodSteps = unknownMethodSteps
        self.recordingMethods = recordingMethods
        self.manualStepsBeforeCoverage = manualStepsBeforeCoverage
        self.trustedWearable = trustedWearable ?? kind.isWearable
        self.lateWrittenSteps = lateWrittenSteps
        self.hourlySteps = hourlySteps
        self.activeCalories = activeCalories
        self.distanceSource = distanceSource
        self.isPlatform = isPlatform
    }

    var isWearable: Bool { kind.isWearable }

    /// Android's `excludingManual`: the counted share only, distance re-derived.
    func excludingManual() -> StepSource {
        guard manualSteps > 0 else { return self }
        let kept = max(0, steps - manualSteps)
        let before: Int
        if stepsBeforeCoverage < 0 {
            before = -1
        } else if manualStepsBeforeCoverage >= 0 {
            before = min(max(stepsBeforeCoverage - manualStepsBeforeCoverage, 0), kept)
        } else {
            before = min(max(stepsBeforeCoverage - manualSteps, 0), kept)
        }
        var copy = self
        copy.steps = kept
        copy.distance = 0
        copy.calories = 0
        copy.stepsBeforeCoverage = before
        copy.distanceSource = DistanceSource.none
        return copy
    }

    /// The `StepSource` shape, key for key as Android's `toMap`.
    func json() -> JSON {
        .object([
            ("packageName", .string(packageName)),
            ("appName", .string(appName)),
            ("kind", .string(kind.rawValue)),
            ("steps", .int(steps)),
            ("distance", .double(distance)),
            ("calories", .double(calories)),
            ("lastRecordAt", .int(lastRecordAt)),
            ("isSelf", .bool(isSelf)),
            ("isWearable", .bool(isWearable)),
            ("isPlatform", .bool(isPlatform)),
            ("manualSteps", .int(manualSteps)),
            ("unknownMethodSteps", .int(unknownMethodSteps)),
            ("recordingMethods", recordingMethods?.json() ?? .null),
            ("trustedWearable", .bool(trustedWearable)),
            ("lateWrittenSteps", .int(lateWrittenSteps)),
            ("hourlySteps", .ints(hourlySteps)),
            ("activeCalories", .double(activeCalories)),
            ("distanceSource", .string(distanceSource)),
        ])
    }
}

/// Which sources earn the `catalog` trust rule. Android's catalog is package
/// names; iOS's is bundle ids plus Apple's own watch, so the rule takes the
/// whole source.
struct SourceCatalog {
    var isKnownWearable: (StepSource) -> Bool

    static let none = SourceCatalog { _ in false }
}

/// The one place the wearable-trust rule lives - Android's `StepSourceTrust`.
enum StepSourceTrust {
    static func isTrustedWearable(_ source: StepSource, trust: WearableTrust, allowlist: Set<String>, catalog: SourceCatalog) -> Bool {
        switch trust {
        case .metadata:
            return source.isWearable
        case .catalog:
            // The platform's own phone count is never a wearable, whatever
            // the allowlist says. (On Android every platform source is a
            // phone; on iOS Apple Watch is platform too, and is a wearable.)
            if source.isSelf || (source.isPlatform && !source.isWearable) { return false }
            return catalog.isKnownWearable(source) || allowlist.contains(source.packageName)
        }
    }

    static func stamp(_ sources: [StepSource], trust: WearableTrust, allowlist: Set<String>, catalog: SourceCatalog) -> [StepSource] {
        sources.map { source in
            var copy = source
            copy.trustedWearable = isTrustedWearable(source, trust: trust, allowlist: allowlist, catalog: catalog)
            return copy
        }
    }
}
