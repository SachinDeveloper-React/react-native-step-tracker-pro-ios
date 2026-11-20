import Foundation

/// The pedometer's counts for the hours that can no longer change, with
/// their minutes.
///
/// An hour with steps costs sixty minute queries, so without this every
/// count of today asks again for every hour since midnight. An hour is
/// settled once `DayPolicy.settleAfterMs` has passed since it ended - the
/// iPhone's last record in it has landed - and from then on its counts are
/// read from here. Kept on disk: a background wake from Apple Health is
/// often a new process, and then asks the pedometer only for the hours
/// still moving.
///
/// An hour is the exact stretch counted, so one a window starts or ends
/// inside has its own entry. The pedometer answers by wall-clock time, so
/// what is kept holds for one boot and one setting of the clock - an hour
/// settled while the clock ran ahead holds steps not yet taken.
/// `kern.boottime` moves with both, and is kept with the hours.
struct HourCache {
    /// A reboot or a clock edit moves the boot time by more than this; the
    /// clock's own small corrections do not.
    static let bootToleranceMs: Int64 = 60_000

    private(set) var bootTimeMs: Int64
    private var hours: [Span: BucketCount] = [:]
    /// Changed since it was last written.
    private(set) var unsaved = false

    private struct Span: Hashable {
        let startMs: Int64
        let endMs: Int64
    }

    init(bootTimeMs: Int64) {
        self.bootTimeMs = bootTimeMs
    }

    var count: Int { hours.count }

    static func isSettled(endMs: Int64, now: Int64) -> Bool { endMs <= now - DayPolicy.settleAfterMs }

    func hour(from: Int64, to: Int64) -> BucketCount? { hours[Span(startMs: from, endMs: to)] }

    mutating func keep(_ hour: BucketCount) {
        hours[Span(startMs: hour.startMs, endMs: hour.endMs)] = hour
        unsaved = true
    }

    /// Forgets every hour when the boot time moved: a reboot, a clock edit.
    mutating func check(bootTimeMs now: Int64) {
        guard abs(now - bootTimeMs) > HourCache.bootToleranceMs else { return }
        bootTimeMs = now
        if !hours.isEmpty {
            hours.removeAll()
            unsaved = true
        }
    }

    /// Forgets the hours that end at or before [ms].
    mutating func prune(endingBy ms: Int64) {
        let kept = hours.filter { $0.key.endMs > ms }
        if kept.count != hours.count {
            hours = kept
            unsaved = true
        }
    }

    mutating func removeAll() {
        guard !hours.isEmpty else { return }
        hours.removeAll()
        unsaved = true
    }

    mutating func markSaved() { unsaved = false }

    // ---- counting ---------------------------------------------------------------------------

    /// [windows] hour by hour, and each hour with steps minute by minute:
    /// settled hours from here, the rest from [query] - the pedometer, many
    /// intervals at once, nil for any it did not answer. Settled hours that
    /// end after [keepAfter] are kept. Nil when the pedometer did not answer;
    /// hours counted before it failed are kept all the same.
    mutating func count(windows: [(Int64, Int64)], totals: [Int], clock: DayClock, now: Int64, keepAfter: Int64,
                        query: ([(Int64, Int64)]) -> [Int?]) -> [WindowCount]? {
        var counts: [WindowCount] = []
        for (i, w) in windows.enumerated() {
            let spans = TrackingSpans.hours(from: w.0, to: w.1, clock: clock)
            var hours = [BucketCount?](repeating: nil, count: spans.count)
            var needed: [Int] = []
            for (j, h) in spans.enumerated() {
                if HourCache.isSettled(endMs: h.1, now: now), let cached = hour(from: h.0, to: h.1) {
                    hours[j] = cached
                } else {
                    needed.append(j)
                }
            }
            let hourTotals = query(needed.map { spans[$0] })
            guard hourTotals.count == needed.count, !hourTotals.contains(where: { $0 == nil }) else { return nil }
            for (k, j) in needed.enumerated() {
                let h = spans[j]
                var bucket = BucketCount(startMs: h.0, endMs: h.1, total: hourTotals[k] ?? 0)
                if bucket.total > 0 {
                    let minuteSpans = TrackingSpans.minutes(from: h.0, to: h.1)
                    let minuteTotals = query(minuteSpans)
                    guard minuteTotals.count == minuteSpans.count, !minuteTotals.contains(where: { $0 == nil }) else { return nil }
                    bucket.minutes = zip(minuteSpans, minuteTotals).map { BucketCount(startMs: $0.0, endMs: $0.1, total: $1 ?? 0) }
                }
                if HourCache.isSettled(endMs: h.1, now: now) && h.1 > keepAfter { keep(bucket) }
                hours[j] = bucket
            }
            counts.append(WindowCount(startMs: w.0, endMs: w.1, total: i < totals.count ? totals[i] : 0,
                                      hours: hours.compactMap { $0 }))
        }
        return counts
    }

    // ---- on disk ------------------------------------------------------------------------------

    /// Version 1 keeps each hour's minutes as counts alone, in the order
    /// `TrackingSpans.minutes` cuts the hour: a change to that cut is a new
    /// version.
    private struct File: Codable {
        var version: Int
        var bootTimeMs: Int64
        var hours: [Hour]
    }

    private struct Hour: Codable {
        var startMs: Int64
        var endMs: Int64
        var total: Int
        /// Empty for an hour without steps, whose minutes were never asked.
        var minutes: [Int]
    }

    func encoded() -> Data {
        let list = hours.values.sorted { $0.startMs < $1.startMs }.map {
            Hour(startMs: $0.startMs, endMs: $0.endMs, total: $0.total, minutes: $0.minutes.map(\.total))
        }
        return (try? JSONEncoder().encode(File(version: 1, bootTimeMs: bootTimeMs, hours: list))) ?? Data()
    }

    /// Nil for a file this version cannot read. An hour whose minutes do
    /// not fit its stretch is left out, and asked again.
    static func decoded(_ data: Data) -> HourCache? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return nil }
        var cache = HourCache(bootTimeMs: file.bootTimeMs)
        for h in file.hours where h.endMs > h.startMs && h.endMs - h.startMs <= DayClock.hourMs
            && h.total >= 0 && h.minutes.allSatisfy({ $0 >= 0 }) {
            var bucket = BucketCount(startMs: h.startMs, endMs: h.endMs, total: h.total)
            if h.total > 0 {
                let spans = TrackingSpans.minutes(from: h.startMs, to: h.endMs)
                guard spans.count == h.minutes.count else { continue }
                bucket.minutes = zip(spans, h.minutes).map { BucketCount(startMs: $0.0, endMs: $0.1, total: $1) }
            } else if !h.minutes.isEmpty {
                continue
            }
            cache.hours[Span(startMs: h.startMs, endMs: h.endMs)] = bucket
        }
        return cache
    }
}
