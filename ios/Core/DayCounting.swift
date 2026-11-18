import Foundation

/// One `CMMotionActivity`, as plain values: it covers from `startMs` until
/// the next one starts.
struct ActivitySample: Equatable, Codable {
    var startMs: Int64
    var stationary = false
    var walking = false
    var running = false
    var automotive = false
    var cycling = false
    var unknown = false
    /// 0 low, 1 medium, 2 high - `CMMotionActivityConfidence`.
    var confidence = 0

    var onFoot: Bool { walking || running }
    var vehicle: Bool { (automotive || cycling) && !onFoot }
    var informative: Bool { stationary || walking || running || automotive || cycling }

    /// The `ActivityState` an integrity report calls this.
    var state: ActivityState {
        if running { return .running }
        if walking { return .walking }
        if cycling { return .onBicycle }
        if automotive { return .inVehicle }
        if stationary { return .still }
        return .unknown
    }
}

/// What the motion coprocessor says about one minute.
struct MinuteActivity: Equatable {
    /// Steps here go to `gatedSteps`: a vehicle or bicycle with medium or high
    /// confidence covered the minute, nothing said walking or running, and the
    /// walk away from the ride did not claim it.
    var gated = false
    /// A vehicle or bicycle covered it (any confidence) and nothing said
    /// walking or running - tagged `vehicleSteps` unless gated.
    var vehicle = false
    /// Stationary with medium or high confidence, no walking, running or vehicle.
    var still = false
}

/// The motion gate on iOS: the contract of Android's `VehicleGate` - steps
/// counted while the phone rode in a vehicle or on a bicycle are held as
/// `gatedSteps`, out of every minute and every resolved number - judged per
/// minute from `CMMotionActivity` history instead of live, since iOS hands
/// the history over after the fact.
///
/// Mirrored from Android:
///  - nothing is held without a vehicle or bicycle report (and a low-confidence
///    one only tags);
///  - held is not gone: walking or running reported straight after a ride
///    gives back the minutes of the [exitLookbackMs] before it - the
///    coprocessor, like Activity Recognition, says so late, and that time is
///    the walk away from the stop - and so does walking within
///    [onFootGraceMs] after a ride ended on "stationary";
///  - no ride is held for more than [vehicleMaxMs] on one report.
enum ActivityGate {
    static let exitLookbackMs: Int64 = 90_000
    static let onFootGraceMs: Int64 = 60_000
    static let vehicleMaxMs: Int64 = 12 * 3_600_000
    private static let minute = MinuteAttribution.minuteMs

    /// @param untilMs where the last activity stops covering - now, or the day's end.
    static func classify(minutes: [Int64], activities: [ActivitySample], untilMs: Int64, gateEnabled: Bool) -> [Int64: MinuteActivity] {
        let acts = activities.sorted { $0.startMs < $1.startMs }
        guard !acts.isEmpty, !minutes.isEmpty else { return [:] }
        var ends: [Int64] = []
        for (i, a) in acts.enumerated() {
            ends.append(i + 1 < acts.count ? acts[i + 1].startMs : max(untilMs, a.startMs))
        }

        // Where each ride began: a chain of vehicle reports, unbroken by
        // walking, running or plain stationary. Uninformative reports in
        // between leave it standing - the last word stands.
        var rideStart = [Int64?](repeating: nil, count: acts.count)
        var current: Int64?
        for (i, a) in acts.enumerated() {
            if a.vehicle {
                if current == nil { current = a.startMs }
                rideStart[i] = current
            } else if a.informative {
                current = nil
            } else {
                rideStart[i] = current
            }
        }

        // Intervals whose held minutes are given back.
        var releases: [(Int64, Int64)] = []
        for (i, a) in acts.enumerated() where a.onFoot {
            // The last informative report before this walk.
            var j = i - 1
            while j >= 0 && !acts[j].informative { j -= 1 }
            guard j >= 0 else { continue }
            if acts[j].vehicle {
                releases.append((a.startMs - exitLookbackMs, a.startMs))
            } else if acts[j].stationary && !acts[j].onFoot && a.startMs - acts[j].startMs <= onFootGraceMs {
                var k = j - 1
                while k >= 0 && !acts[k].informative { k -= 1 }
                if k >= 0 && acts[k].vehicle {
                    releases.append((acts[j].startMs - exitLookbackMs, a.startMs))
                }
            }
        }

        var out: [Int64: MinuteActivity] = [:]
        var p = 0
        for m in minutes.sorted() {
            let mEnd = m + minute
            while p < acts.count && ends[p] <= m { p += 1 }
            var onFoot = false, vehicleAny = false, vehicleStrong = false, still = false
            var oldestRide: Int64?
            var q = p
            while q < acts.count && acts[q].startMs < mEnd {
                if ends[q] > m {
                    let a = acts[q]
                    if a.onFoot { onFoot = true }
                    if a.vehicle {
                        vehicleAny = true
                        if a.confidence >= 1 {
                            vehicleStrong = true
                            if let r = rideStart[q] { oldestRide = min(oldestRide ?? r, r) }
                        }
                    }
                    if a.stationary && a.confidence >= 1 { still = true }
                }
                q += 1
            }
            var result = MinuteActivity()
            if onFoot { out[m] = result; continue }
            let released = releases.contains { m < $0.1 && mEnd > $0.0 }
            let expired = oldestRide.map { m - $0 > vehicleMaxMs } ?? false
            result.gated = gateEnabled && vehicleStrong && !released && !expired
            result.vehicle = vehicleAny && !result.gated && !released
            result.still = still && !vehicleAny
            if result != MinuteActivity() { out[m] = result }
        }
        return out
    }
}

/// Pedometer counts for one stretch a day is counted over, hour by hour and
/// minute by minute.
struct WindowCount: Equatable {
    var startMs: Int64
    var endMs: Int64
    /// One query over the whole window: the figure the day is reported with.
    var total: Int
    var hours: [BucketCount]
}

struct BucketCount: Equatable {
    var startMs: Int64
    var endMs: Int64
    var total: Int
    /// Only queried for hours with steps.
    var minutes: [BucketCount] = []
}

/// A day of this phone's own count: the raw total, what the gate held, and
/// the minutes that explain the rest.
struct DayCount: Equatable {
    var deviceSteps: Int
    var gatedSteps: Int
    var minutes: [MinuteSample]

    static let empty = DayCount(deviceSteps: 0, gatedSteps: 0, minutes: [])
}

enum DayCounting {
    /// Splits [target] in proportion to [weights], largest remainder first,
    /// so the parts always add back to it. Nil when there is nothing to
    /// weigh by.
    static func fit(_ target: Int, _ weights: [Int]) -> [Int]? {
        let sum = weights.reduce(0) { $0 + max(0, $1) }
        if target == sum { return weights.map { max(0, $0) } }
        guard sum > 0, target >= 0 else { return nil }
        var parts: [Int] = []
        var remainders: [(Int64, Int)] = []
        var assigned = 0
        for (i, w) in weights.enumerated() {
            let exact = Int64(max(0, w)) * Int64(target)
            parts.append(Int(exact / Int64(sum)))
            remainders.append((exact % Int64(sum), i))
            assigned += parts[i]
        }
        remainders.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        var left = target - assigned
        var k = 0
        while left > 0 && !remainders.isEmpty {
            parts[remainders[k % remainders.count].1] += 1
            left -= 1
            k += 1
        }
        return parts
    }

    /// Builds the day from pedometer counts.
    ///
    /// Each window's single query is the truth for its total; its hours are
    /// fitted to it, and each hour's minutes to the hour, by largest
    /// remainder - so `sum(minutes) == deviceSteps - gatedSteps` holds by
    /// construction, whatever rounding the coprocessor does between
    /// queries. An hour with steps but no minute that has any - timing the
    /// pedometer cannot place - is parked untimed at its first minute, as
    /// Android parks steps whose minute is unknown.
    static func build(
        windows: [WindowCount],
        activity: [Int64: MinuteActivity],
        charging: [(Int64, Int64)],
        activityTags: Bool
    ) -> DayCount {
        var byMinute: [Int64: MinuteSample] = [:]
        var device = 0
        var gated = 0

        func isCharging(_ m: Int64) -> Bool {
            charging.contains { m < $0.1 && m + MinuteAttribution.minuteMs > $0.0 }
        }
        func add(_ minuteStart: Int64, timed: Int, untimed: Int) {
            guard timed + untimed > 0 else { return }
            let act = activity[minuteStart] ?? MinuteActivity()
            var timed = timed
            if act.gated {
                gated += timed
                timed = 0
            }
            let total = timed + untimed
            guard total > 0 else { return }
            var sample = byMinute[minuteStart] ?? MinuteSample(minuteStart: minuteStart, steps: 0)
            sample.steps += timed
            sample.untimedSteps += untimed
            if isCharging(minuteStart) { sample.chargingSteps += total }
            if activityTags {
                if act.vehicle { sample.vehicleSteps += total } else if act.still { sample.stillSteps += total }
            }
            byMinute[minuteStart] = sample
        }

        for window in windows where window.total > 0 {
            device += window.total
            guard let hourTotals = fit(window.total, window.hours.map(\.total)) else {
                add(DayClock.minuteOf(window.startMs), timed: 0, untimed: window.total)
                continue
            }
            for (hour, hourTotal) in zip(window.hours, hourTotals) where hourTotal > 0 {
                guard let minuteTotals = fit(hourTotal, hour.minutes.map(\.total)) else {
                    add(DayClock.minuteOf(hour.startMs), timed: 0, untimed: hourTotal)
                    continue
                }
                for (bucket, steps) in zip(hour.minutes, minuteTotals) where steps > 0 {
                    add(DayClock.minuteOf(bucket.startMs), timed: steps, untimed: 0)
                }
            }
        }
        let minutes = byMinute.keys.sorted().compactMap { byMinute[$0] }.filter { $0.totalSteps > 0 }
        return DayCount(deviceSteps: device, gatedSteps: gated, minutes: minutes)
    }

    /// The Apple Health fallback: per-minute sums from this iPhone's own
    /// built-in source, taken as they are - no gate, no tags (the motion
    /// history is gone by then too).
    static func fromHealthMinutes(_ minutes: [Int64: Int]) -> DayCount {
        let samples = minutes.keys.sorted().compactMap { m -> MinuteSample? in
            let steps = minutes[m] ?? 0
            return steps > 0 ? MinuteSample(minuteStart: m, steps: steps) : nil
        }
        return DayCount(deviceSteps: samples.reduce(0) { $0 + $1.steps }, gatedSteps: 0, minutes: samples)
    }
}

/// When tracking was running: steps outside these spans are not this
/// phone's count, as on Android, where nothing counts while tracking is
/// paused or stopped.
struct TrackingSpan: Codable, Equatable {
    var start: Int64
    /// Nil while it is still running.
    var end: Int64?
}

enum TrackingSpans {
    /// The stretches of [from, to) inside a span, sorted and merged.
    static func windows(_ spans: [TrackingSpan], from: Int64, to: Int64) -> [(Int64, Int64)] {
        guard to > from else { return [] }
        let clipped = spans.compactMap { span -> (Int64, Int64)? in
            let start = max(span.start, from)
            let end = min(span.end ?? to, to)
            return end > start ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }
        var merged: [(Int64, Int64)] = []
        for w in clipped {
            if let last = merged.last, w.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, w.1)
            } else {
                merged.append(w)
            }
        }
        return merged
    }

    /// Spans kept: those that end after [cutoff], or still run.
    static func pruned(_ spans: [TrackingSpan], before cutoff: Int64) -> [TrackingSpan] {
        spans.filter { ($0.end ?? Int64.max) > cutoff }
    }

    /// Clock-hour buckets of [from, to), each clipped to the window.
    static func hours(from: Int64, to: Int64, clock: DayClock) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        var cursor = from
        while cursor < to {
            let next = min(clock.hourStart(ofMs: cursor) + DayClock.hourMs, to)
            out.append((cursor, next))
            cursor = next
        }
        return out
    }

    /// Minute buckets of [from, to), each clipped to the window.
    static func minutes(from: Int64, to: Int64) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        var cursor = from
        while cursor < to {
            let next = min(DayClock.minuteOf(cursor) + DayClock.minuteMs, to)
            out.append((cursor, next))
            cursor = next
        }
        return out
    }
}
