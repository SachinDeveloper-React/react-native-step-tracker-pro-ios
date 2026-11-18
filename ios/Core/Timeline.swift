import Foundation

/// Health records against countFrom - the instant before which nothing is
/// counted. The port of Android's `CountFrom`: a sample that ends by then
/// counts nothing, one that starts then or later counts whole, and one that
/// straddles it counts its share after it, by time.
enum CountFrom {
    static func shareAfter(_ value: Int, startMs: Int64, endMs: Int64, floorMs: Int64) -> Int {
        if floorMs <= 0 || startMs >= floorMs { return value }
        if endMs <= floorMs { return 0 }
        return Int(Int64(value) * (endMs - floorMs) / (endMs - startMs))
    }

    static func shareAfter(_ value: Double, startMs: Int64, endMs: Int64, floorMs: Int64) -> Double {
        if floorMs <= 0 || startMs >= floorMs { return value }
        if endMs <= floorMs { return 0 }
        return value * Double(endMs - floorMs) / Double(endMs - startMs)
    }

    static func startAfter(_ startMs: Int64, floorMs: Int64) -> Int64 { max(startMs, floorMs) }
}

/// Splits a sample across the local hours of the day it started on - the
/// port of Android's `HourlySteps`. Cumulative rounding, so the hours always
/// add back to the sample; whatever runs past midnight stays in hour 23.
enum HourlySteps {
    static let hours = 24
    static let unknown = [Int](repeating: -1, count: 24)

    static func add(into: inout [Int], startMs: Int64, endMs: Int64, count: Int, clock: DayClock) {
        guard count > 0 else { return }
        let span = endMs - startMs
        let startHour = clock.hour(ofMs: startMs)
        if span <= 0 {
            into[startHour] += count
            return
        }
        let dayEnd = clock.endOfDayExclusiveMs(clock.key(ms: startMs))
        var cursor = clock.hourStart(ofMs: startMs)
        var covered: Int64 = 0
        var assigned = 0
        var guardCount = 0
        while true {
            let hourStart = max(cursor, startMs)
            // An hour on the instant time-line, as ZonedDateTime.plusHours.
            let next = cursor + DayClock.hourMs
            let hourEnd = min(next, endMs, dayEnd)
            if hourEnd > hourStart { covered += hourEnd - hourStart }
            let last = hourEnd >= endMs || hourEnd >= dayEnd
            let upTo = last ? count : Int((Int64(count) * covered + span / 2) / span)
            let share = max(0, upTo - assigned)
            into[clock.hour(ofMs: cursor)] += share
            assigned += share
            guardCount += 1
            if last || guardCount > 48 { break }
            cursor = next
        }
    }
}

/// One minute of this device's own steps - Android's `MinuteSample`, the
/// shape of `StepMinute`. Only minutes with steps exist.
struct MinuteSample: Equatable, Codable {
    var minuteStart: Int64
    var steps: Int
    var untimedSteps: Int = 0
    var chargingSteps: Int = 0
    var stillSteps: Int = 0
    var vehicleSteps: Int = 0

    var totalSteps: Int { steps + untimedSteps }

    func json() -> JSON {
        .object([
            ("minuteStart", .int(minuteStart)),
            ("steps", .int(steps)),
            ("untimedSteps", .int(untimedSteps)),
            ("chargingSteps", .int(chargingSteps)),
            ("stillSteps", .int(stillSteps)),
            ("vehicleSteps", .int(vehicleSteps)),
        ])
    }
}

/// What the phone was doing - Android's `ActivityState`.
enum ActivityState: String {
    case unknown, still, walking, running
    case onBicycle = "on_bicycle"
    case inVehicle = "in_vehicle"

    var carried: Bool { self == .inVehicle || self == .onBicycle }
    var onFoot: Bool { self == .walking || self == .running }
}

/// Places a step delta on the minutes it was taken in - the port of
/// Android's `MinuteAttribution`, rules and all. On iOS the pedometer
/// already answers per minute, so this places Apple Health samples (the
/// fallback for days the pedometer no longer remembers) and is kept
/// identical so the two platforms bucket the same interval the same way.
enum MinuteAttribution {
    static let minuteMs: Int64 = 60_000
    static let maxTimedGapMs: Int64 = 60_000
    static let lumpSteps = 20

    struct Share: Equatable {
        let minuteStart: Int64
        let timed: Int
        let untimed: Int
    }

    static func minuteOf(_ ms: Int64) -> Int64 { DayClock.minuteOf(ms) }

    static func attribute(_ fromMs: Int64, _ toMs: Int64, _ steps: Int, timed: Bool = true) -> [Share] {
        guard steps > 0, toMs > 0 else { return [] }
        let arrival = minuteOf(toMs)
        if !timed { return [Share(minuteStart: arrival, timed: 0, untimed: steps)] }
        let gap = toMs - fromMs
        if fromMs <= 0 || gap <= 0 { return [park(arrival, steps)] }
        if gap > maxTimedGapMs { return [park(arrival, steps)] }
        let first = minuteOf(fromMs)
        if first == arrival { return [Share(minuteStart: arrival, timed: steps, untimed: 0)] }
        var shares: [Share] = []
        var minute = first
        var covered: Int64 = 0
        var assigned = 0
        while minute <= arrival {
            let overlap = min(toMs, minute + minuteMs) - max(fromMs, minute)
            covered += max(0, overlap)
            let upTo = minute == arrival ? steps : Int((Int64(steps) * covered + gap / 2) / gap)
            let share = max(0, upTo - assigned)
            if share > 0 { shares.append(Share(minuteStart: minute, timed: share, untimed: 0)) }
            assigned += share
            minute += minuteMs
        }
        return shares
    }

    private static func park(_ minute: Int64, _ steps: Int) -> Share {
        steps <= lumpSteps ? Share(minuteStart: minute, timed: steps, untimed: 0)
            : Share(minuteStart: minute, timed: 0, untimed: steps)
    }

    /// Android's `spread`: as `attribute`, but a lump is spread over the
    /// interval it covers. Used for Apple Health samples, which do say when
    /// they were taken: a sample's interval is its timing, not a silence.
    static func spread(_ fromMs: Int64, _ toMs: Int64, _ steps: Int, timed: Bool = true) -> [Int64: Int] {
        guard steps > 0, toMs > 0 else { return [:] }
        let arrival = minuteOf(toMs)
        let gap = toMs - fromMs
        if !timed || fromMs <= 0 || gap <= 0 { return [arrival: steps] }
        if gap > maxTimedGapMs && steps <= lumpSteps { return [arrival: steps] }
        var out: [Int64: Int] = [:]
        var minute = minuteOf(fromMs)
        var covered: Int64 = 0
        var assigned = 0
        while minute <= arrival {
            let overlap = min(toMs, minute + minuteMs) - max(fromMs, minute)
            covered += max(0, overlap)
            let upTo = minute == arrival ? steps : Int((Int64(steps) * covered + gap / 2) / gap)
            let share = max(0, upTo - assigned)
            if share > 0 { out[minute] = share }
            assigned += share
            minute += minuteMs
        }
        return out
    }
}

/// Per-minute increments with their tags - the port of Android's
/// `StepTimeline`, used to build the Apple Health fallback's minutes.
final class StepTimeline {
    private struct Pending {
        var timed = 0, untimed = 0, charging = 0, still = 0, vehicle = 0
    }

    static let maxPendingMinutes = 2 * 24 * 60
    private var pending: [Int64: Pending] = [:]

    func record(_ fromMs: Int64, _ toMs: Int64, _ steps: Int, charging: Bool, activity: ActivityState, timed: Bool = true) {
        for share in MinuteAttribution.attribute(fromMs, toMs, steps, timed: timed) {
            var entry = pending[share.minuteStart] ?? Pending()
            let total = share.timed + share.untimed
            entry.timed += share.timed
            entry.untimed += share.untimed
            if charging { entry.charging += total }
            switch activity {
            case .still: entry.still += total
            case .inVehicle, .onBicycle: entry.vehicle += total
            case .unknown, .walking, .running: break
            }
            pending[share.minuteStart] = entry
        }
        while pending.count > StepTimeline.maxPendingMinutes, let oldest = pending.keys.min() {
            pending.removeValue(forKey: oldest)
        }
    }

    func drain() -> [MinuteSample] {
        let out = pending.keys.sorted().map { minute -> MinuteSample in
            let p = pending[minute]!
            return MinuteSample(minuteStart: minute, steps: p.timed, untimedSteps: p.untimed,
                                chargingSteps: p.charging, stillSteps: p.still, vehicleSteps: p.vehicle)
        }
        pending.removeAll()
        return out
    }

    func clear() { pending.removeAll() }
}
