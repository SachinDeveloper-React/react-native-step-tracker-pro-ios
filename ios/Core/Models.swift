import Foundation

/// Mirrors the `TrackingState` union in types.ts.
enum TrackingState: String, Codable {
    case idle, running, paused, stopped, unsupported
}

/// How a multi-day read of the health store went - Android's `HealthConnectRead`.
enum HealthRead {
    static let read = "read"
    static let notConsulted = "not_consulted"
    static let timedOut = "timed_out"
    static let failed = "failed"
    static let rateLimited = "rate_limited"
}

/// One day's totals: this device's own count, or a resolved one.
struct DayTotals: Equatable {
    var date: String
    var steps: Int
    var distance: Double
    var calories: Double
    var synced: Bool = false
    var syncedRemote: Bool = false
    var recoveredSteps: Int = 0
    var suspectSteps: Int = 0
    var gatedSteps: Int = 0

    /// As `DayRecord` - Android's `Bridge.day`, distance and calories to two places.
    func json(stepSource: JSON? = nil) -> JSON {
        var pairs: [(String, JSON)] = [
            ("date", .string(date)),
            ("steps", .int(steps)),
            ("distance", .double(Rounding.round(distance, 2))),
            ("calories", .double(Rounding.round(calories, 2))),
            ("synced", .bool(synced)),
            ("syncedRemote", .bool(syncedRemote)),
            ("recoveredSteps", .int(recoveredSteps)),
            ("suspectSteps", .int(suspectSteps)),
            ("gatedSteps", .int(gatedSteps)),
        ]
        if let stepSource { pairs.append(("stepSource", stepSource)) }
        return .object(pairs)
    }
}

/// A live view of today, as `stepsChanged` and `getTodaySteps()` carry it.
struct StepSnapshot: Equatable {
    var date: String
    var steps: Int
    var distance: Double
    var calories: Double
    var dailyGoal: Int
    var goalProgress: Double
    var goalReached: Bool
    var state: TrackingState
    var source: String
    var timestamp: Int64
    var recoveredSteps: Int = 0
    var suspectSteps: Int = 0
    var gatedSteps: Int = 0
    var otherDevicesSteps: Int = 0

    /// Android's `Bridge.snapshotMap`, plus the resolution as `stepSource`.
    func json(stepSource: JSON) -> JSON {
        .object([
            ("date", .string(date)),
            ("steps", .int(steps)),
            ("distance", .double(Rounding.round(distance, 2))),
            ("calories", .double(Rounding.round(calories, 2))),
            ("dailyGoal", .int(dailyGoal)),
            ("goalProgress", .double(Rounding.round(goalProgress, 4))),
            ("goalReached", .bool(goalReached)),
            ("state", .string(state.rawValue)),
            ("source", .string(source)),
            ("timestamp", .int(timestamp)),
            ("recoveredSteps", .int(recoveredSteps)),
            ("suspectSteps", .int(suspectSteps)),
            ("gatedSteps", .int(gatedSteps)),
            ("otherDevicesSteps", .int(otherDevicesSteps)),
            ("stepSource", stepSource),
        ])
    }
}

struct RangeStats {
    var startDate: String
    var endDate: String
    var totalSteps: Int
    var totalDistance: Double
    var totalCalories: Double
    var averageSteps: Int
    var activeDays: Int
    var bestDay: DayTotals?
    var days: [DayTotals]
    var goal: Int?
    var goalProgress: Double?
    var healthConnect: String?

    /// Android's `Bridge.stats`.
    func json() -> JSON {
        var pairs: [(String, JSON)] = [
            ("startDate", .string(startDate)),
            ("endDate", .string(endDate)),
            ("totalSteps", .int(totalSteps)),
            ("totalDistance", .double(Rounding.round(totalDistance, 2))),
            ("totalCalories", .double(Rounding.round(totalCalories, 2))),
            ("averageSteps", .int(averageSteps)),
            ("activeDays", .int(activeDays)),
            ("bestDay", bestDay?.json() ?? .null),
            ("days", .array(days.map { $0.json() })),
        ]
        if let goal { pairs.append(("goal", .int(goal))) }
        if let goalProgress { pairs.append(("goalProgress", .double(Rounding.round(goalProgress, 4)))) }
        if let healthConnect { pairs.append(("healthConnect", .string(healthConnect))) }
        return .object(pairs)
    }

    /// Android's `StepRepository.stats` / `recomputeStats`: totals over the
    /// days given, the average over elapsed days only.
    static func of(start: String, end: String, days: [DayTotals], goal: Int?, today: String, clock: DayClock) -> RangeStats {
        let total = days.reduce(0) { $0 + $1.steps }
        let elapsed: Int
        if start <= today && today <= end {
            elapsed = clock.daysBetween(start, today < end ? today : end)
        } else {
            elapsed = days.count
        }
        let best = days.max(by: { $0.steps < $1.steps }).flatMap { $0.steps > 0 ? $0 : nil }
        return RangeStats(
            startDate: start,
            endDate: end,
            totalSteps: total,
            totalDistance: days.reduce(0) { $0 + $1.distance },
            totalCalories: days.reduce(0) { $0 + $1.calories },
            averageSteps: total / max(elapsed, 1),
            activeDays: days.filter { $0.steps > 0 }.count,
            bestDay: best,
            days: days,
            goal: goal,
            goalProgress: goal.flatMap { $0 > 0 ? min(1, max(0, Double(total) / Double($0))) : nil },
            healthConnect: nil
        )
    }
}

enum Rounding {
    /// Android's `Bridge.round`: half away from zero, 0 for NaN and infinity.
    static func round(_ value: Double, _ decimals: Int) -> Double {
        guard value.isFinite else { return 0 }
        var factor = 1.0
        for _ in 0..<decimals { factor *= 10 }
        return (value * factor).rounded(.toNearestOrAwayFromZero) / factor
    }
}

/// Distance and calories from steps - the port of Android's
/// `MetricsCalculator`. Every calorie figure on iOS comes from here, never
/// from Apple Health's energy, so the same walk reads the same on both
/// platforms.
struct MetricsCalculator {
    var config: StepTrackerConfig

    /// Metres.
    func distance(_ steps: Int) -> Double { Double(max(0, steps)) * effectiveStride }

    /// Kilocalories: `coefficient x kg x km`.
    func calories(_ steps: Int) -> Double {
        config.calorieCoefficient * config.weightKg * (distance(steps) / 1000)
    }

    func totals(date: String, steps: Int, recoveredSteps: Int = 0, gatedSteps: Int = 0) -> DayTotals {
        DayTotals(date: date, steps: steps, distance: distance(steps), calories: calories(steps),
                  recoveredSteps: recoveredSteps, gatedSteps: gatedSteps)
    }

    func goalProgress(_ steps: Int, goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(1, max(0, Double(steps) / Double(goal)))
    }

    func goalPercent(_ steps: Int, goal: Int) -> Int {
        Int((goalProgress(steps, goal: goal) * 100).rounded(.toNearestOrAwayFromZero))
    }

    var effectiveStride: Double {
        if config.strideLengthM > 0 { return config.strideLengthM }
        let coefficient: Double
        switch config.sex {
        case "male": coefficient = 0.415
        case "female": coefficient = 0.413
        default: coefficient = 0.414
        }
        return config.heightCm * coefficient / 100
    }
}
