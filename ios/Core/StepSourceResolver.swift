import Foundation

/// Picks the number a day is reported with - the port of Android's
/// `StepSourceResolver`, unchanged. Origins are never summed: every policy
/// selects exactly one per day.
enum StepSourceResolver {
    struct Resolution: Equatable {
        var totals: DayTotals
        var kind: StepSourceKind
        var sourcePackage: String?
        var sourceName: String
        var deviceSteps: Int
        var externalSteps: Int
        var usedExternal: Bool
        var merged = false
        var baselineSteps = 0
        var manualStepsExcluded = 0
        var suspectStepsExcluded = 0
        var distanceSource = DistanceSource.derived

        /// `ResolvedStepSource`, key for key.
        func json() -> JSON {
            .object([
                ("date", .string(totals.date)),
                ("steps", .int(totals.steps)),
                ("kind", .string(kind.rawValue)),
                ("packageName", .optional(sourcePackage)),
                ("appName", .string(sourceName)),
                ("deviceSteps", .int(deviceSteps)),
                ("externalSteps", .int(externalSteps)),
                ("usedExternal", .bool(usedExternal)),
                ("merged", .bool(merged)),
                ("baselineSteps", .int(baselineSteps)),
                ("manualStepsExcluded", .int(manualStepsExcluded)),
                ("suspectStepsExcluded", .int(suspectStepsExcluded)),
                ("distanceSource", .string(distanceSource)),
            ])
        }
    }

    /// The display name of this device's own count.
    static let deviceName = "This device"

    /// @param measuredDistance what a winning source's own distance is
    ///   called: `health_connect` on Android, `healthkit` on iOS.
    static func resolve(
        _ policy: StepSourcePolicy,
        device: DayTotals,
        sources: [StepSource],
        preferredPackage: String?,
        metrics: MetricsCalculator,
        deviceCoverageReliable: Bool = true,
        ignoreManualEntries: Bool = false,
        wearableTrust: WearableTrust = .metadata,
        wearableAllowlist: Set<String> = [],
        catalog: SourceCatalog = .none,
        measuredDistance: String = DistanceSource.healthKit
    ) -> Resolution {
        let deviceResolution = Resolution(
            totals: device, kind: .selfSource, sourcePackage: nil, sourceName: deviceName,
            deviceSteps: device.steps, externalSteps: 0, usedExternal: false)
        if policy == .device { return deviceResolution }

        let external = sources.filter { !$0.isSelf }.map { ignoreManualEntries ? $0.excludingManual() : $0 }
        if external.isEmpty { return deviceResolution }

        let pinned = preferredPackage.flatMap { $0.isEmpty ? nil : $0 }
        if let pinned, !external.contains(where: { $0.packageName == pinned }) {
            if sources.contains(where: { $0.isSelf && $0.packageName == pinned }) { return deviceResolution }
        }

        func isTrusted(_ s: StepSource) -> Bool {
            pinned != nil
                || StepSourceTrust.isTrustedWearable(s, trust: wearableTrust, allowlist: wearableAllowlist, catalog: catalog)
                || !deviceCoverageReliable
        }
        func leadOf(_ s: StepSource) -> Int {
            if isTrusted(s) { return s.steps - device.steps }
            if s.stepsBeforeCoverage >= 0 { return s.stepsBeforeCoverage }
            if device.steps == 0 { return s.steps }
            return 0
        }
        func mostSteps(_ list: [StepSource]) -> StepSource? {
            // Kotlin's maxByOrNull keeps the first of equals.
            list.reduce(nil) { best, s in best == nil || s.steps > best!.steps ? s : best }
        }

        let candidate: StepSource?
        if let pinned {
            candidate = external.first { $0.packageName == pinned }
        } else if policy == .wearable {
            candidate = mostSteps(external.filter(\.isWearable))
        } else if policy == .auto {
            let ahead = external.filter { leadOf($0) > 0 }
            // compareBy(lead, trusted, steps); maxWithOrNull keeps the first of equals.
            let best = ahead.reduce(nil as StepSource?) { best, s in
                guard let b = best else { return s }
                let l = (leadOf(s), isTrusted(s) ? 1 : 0, s.steps)
                let r = (leadOf(b), isTrusted(b) ? 1 : 0, b.steps)
                return l > r ? s : b
            }
            candidate = best ?? mostSteps(external)
        } else {
            candidate = mostSteps(external)
        }
        guard let candidate else {
            var r = deviceResolution
            r.externalSteps = external.map(\.steps).max() ?? 0
            return r
        }

        let externalSteps = candidate.steps
        let excluded = ignoreManualEntries ? max(0, candidate.manualSteps) : 0

        if externalSteps <= 0 && excluded > 0 {
            var r = deviceResolution
            r.externalSteps = 0
            r.manualStepsExcluded = excluded
            return r
        }

        if policy == .wearable || policy == .healthConnect {
            return externalResolution(device, candidate, externalSteps, metrics, merged: false, lead: 0, excluded: excluded, measuredDistance)
        }

        let trusted = isTrusted(candidate)
        let lead = leadOf(candidate)
        if lead <= 0 {
            var r = deviceResolution
            r.externalSteps = externalSteps
            r.manualStepsExcluded = excluded
            return r
        }
        if trusted {
            return externalResolution(device, candidate, externalSteps, metrics, merged: false, lead: lead, excluded: excluded, measuredDistance)
        }
        return externalResolution(device, candidate, device.steps + lead, metrics, merged: true, lead: lead, excluded: excluded, measuredDistance)
    }

    private static func externalResolution(_ device: DayTotals, _ candidate: StepSource, _ steps: Int, _ metrics: MetricsCalculator,
                                           merged: Bool, lead: Int, excluded: Int, _ measuredDistance: String) -> Resolution {
        let ownDistance = candidate.distance > 0 && !merged
        // On iOS a source's calories are always 0 - Apple Health's energy is
        // never read - so they are always this package's step formula.
        let ownCalories = candidate.calories > 0 && !merged
        return Resolution(
            totals: DayTotals(
                date: device.date, steps: steps,
                distance: ownDistance ? candidate.distance : metrics.distance(steps),
                calories: ownCalories ? candidate.calories : metrics.calories(steps),
                synced: device.synced, syncedRemote: device.syncedRemote,
                recoveredSteps: device.recoveredSteps),
            kind: candidate.kind, sourcePackage: candidate.packageName, sourceName: candidate.appName,
            deviceSteps: device.steps, externalSteps: candidate.steps, usedExternal: true,
            merged: merged, baselineSteps: max(0, lead), manualStepsExcluded: excluded,
            distanceSource: ownDistance ? measuredDistance : DistanceSource.derived)
    }
}

/// Keeps the number shown moving when another source is ahead of the phone -
/// the port of Android's `StepContinuity`. Only `auto` uses it.
enum StepContinuity {
    struct Baseline: Equatable, Codable {
        var date: String
        var offset: Int
        var packageName: String?
        var kind: String
        var appName: String
        var observedAt: Int64
    }

    static func observe(_ current: Baseline?, raw: StepSourceResolver.Resolution, date: String, now: Int64) -> Baseline? {
        let stored = current?.date == date ? current : nil
        if raw.externalSteps <= 0 { return stored }
        let lead = raw.usedExternal ? raw.totals.steps - raw.deviceSteps : 0
        if lead <= (stored?.offset ?? 0) { return stored }
        return Baseline(
            date: date, offset: lead,
            packageName: raw.usedExternal ? raw.sourcePackage : stored?.packageName,
            kind: raw.usedExternal ? raw.kind.rawValue : (stored?.kind ?? raw.kind.rawValue),
            appName: raw.usedExternal ? raw.sourceName : (stored?.appName ?? raw.sourceName),
            observedAt: now)
    }

    static func apply(_ raw: StepSourceResolver.Resolution, baseline: Baseline?, metrics: MetricsCalculator) -> StepSourceResolver.Resolution {
        guard let baseline, baseline.offset > 0, baseline.date == raw.totals.date else { return raw }
        let merged = raw.deviceSteps + baseline.offset
        if merged <= raw.totals.steps {
            var r = raw
            r.merged = true
            r.baselineSteps = baseline.offset
            return r
        }
        return StepSourceResolver.Resolution(
            totals: DayTotals(date: raw.totals.date, steps: merged, distance: metrics.distance(merged),
                              calories: metrics.calories(merged), synced: raw.totals.synced,
                              syncedRemote: raw.totals.syncedRemote, recoveredSteps: raw.totals.recoveredSteps,
                              suspectSteps: raw.totals.suspectSteps),
            kind: StepSourceKind(rawValue: baseline.kind) ?? .unknown,
            sourcePackage: baseline.packageName, sourceName: baseline.appName,
            deviceSteps: raw.deviceSteps, externalSteps: raw.externalSteps, usedExternal: true,
            merged: true, baselineSteps: baseline.offset, manualStepsExcluded: raw.manualStepsExcluded,
            suspectStepsExcluded: raw.suspectStepsExcluded, distanceSource: DistanceSource.derived)
    }
}
