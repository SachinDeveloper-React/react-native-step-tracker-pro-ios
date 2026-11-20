import Foundation

/// When a day stops changing, and what an aged-out day is settled on.
enum DayPolicy {
    /// How long after midnight a day is still recomputed. The iPhone writes
    /// its step records late - each covers up to ten minutes and lands when
    /// it ends, or later on an idle phone - so a day closed at once loses the
    /// walk at its end. Two hours is long past any record that ends it.
    static let settleAfterMs: Int64 = 2 * 3_600_000

    /// A count computed at [computedAt] never changes again.
    static func isSettled(computedAt: Int64, dayEndExclusive: Int64) -> Bool {
        computedAt >= dayEndExclusive + settleAfterMs
    }

    /// What a day past the pedometer's week is settled on, given what was
    /// counted (nil when nothing was) and what Apple Health's record of this
    /// iPhone holds (nil when it could not be read).
    enum AgedDay: Equatable {
        /// Leave it as it is, and ask again later.
        case keep
        /// What was counted stands; it never changes again.
        case settle
        /// Apple Health holds more of the day: take its count.
        case replace
    }

    static func agedDay(counted: Int?, health: Int?) -> AgedDay {
        // A read that failed - a locked phone, no grant - decides nothing.
        guard let health else { return .keep }
        if let counted, counted >= health {
            // Apple Health answers a refused read with no data, so a zero
            // settles nothing.
            return health > 0 ? .settle : .keep
        }
        return health > 0 ? .replace : .keep
    }
}

/// The Health app's way of not losing a walk: where the phone and a watch
/// both counted, the larger of the two; where only one did, that one. Done
/// per local hour, never summing the same hour twice.
///
/// Android's resolver picks one origin for the whole day, so a morning
/// walked with only the watch and an evening with only the phone loses one
/// of them. On iOS the `auto` policy (with nothing pinned) also merges this
/// phone with every trusted wearable hour by hour, and takes the merge when
/// it is larger. Each source's own figures are untouched, for a server.
enum HourMerge {
    /// This phone's counted steps by local clock hour, fitted to [total] -
    /// its count after the gate and, under exclude mode, the flagged steps.
    ///
    /// @param currentHour today's hour now. A total ahead of the minutes is
    ///   steps taken since they were last counted - now, not in the morning:
    ///   spread over the day's earlier hours, they would be counted again
    ///   wherever a watch saw the same walk this hour.
    static func phoneHours(_ minutes: [MinuteSample], total: Int, clock: DayClock, currentHour: Int? = nil) -> [Int] {
        var hours = [Int](repeating: 0, count: 24)
        for m in minutes { hours[clock.hour(ofMs: m.minuteStart)] += m.totalSteps }
        let counted = hours.reduce(0, +)
        if counted == total { return hours }
        if total > counted, let hour = currentHour, (0..<24).contains(hour) {
            hours[hour] += total - counted
            return hours
        }
        return DayCounting.fit(max(0, total), hours) ?? hours
    }

    static func apply(
        _ resolution: StepSourceResolver.Resolution,
        device: DayTotals,
        phoneHours: [Int],
        sources: [StepSource],
        trust: WearableTrust,
        allowlist: Set<String>,
        catalog: SourceCatalog,
        ignoreManualEntries: Bool,
        metrics: MetricsCalculator
    ) -> StepSourceResolver.Resolution {
        guard phoneHours.count == 24 else { return resolution }
        let wearables = sources.filter { source in
            !source.isSelf
                && StepSourceTrust.isTrustedWearable(source, trust: trust, allowlist: allowlist, catalog: catalog)
                && source.hourlySteps.count == 24 && !source.hourlySteps.contains { $0 < 0 }
                // A typed-in number never rides along when it is to be left out.
                && !(ignoreManualEntries && source.manualSteps > 0)
        }
        guard !wearables.isEmpty else { return resolution }
        var total = 0
        for hour in 0..<24 {
            total += max(phoneHours[hour], wearables.map { $0.hourlySteps[hour] }.max() ?? 0)
        }
        guard total > resolution.totals.steps else { return resolution }
        let lead = wearables.reduce(wearables[0]) { $1.steps > $0.steps ? $1 : $0 }
        return StepSourceResolver.Resolution(
            totals: DayTotals(date: device.date, steps: total, distance: metrics.distance(total),
                              calories: metrics.calories(total), synced: device.synced,
                              syncedRemote: device.syncedRemote, recoveredSteps: device.recoveredSteps),
            kind: lead.kind, sourcePackage: lead.packageName, sourceName: lead.appName,
            deviceSteps: device.steps, externalSteps: lead.steps, usedExternal: true,
            merged: true, baselineSteps: total - device.steps,
            manualStepsExcluded: resolution.manualStepsExcluded,
            suspectStepsExcluded: resolution.suspectStepsExcluded,
            distanceSource: DistanceSource.derived)
    }
}
